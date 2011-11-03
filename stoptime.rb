#!/usr/bin/env camping
#
# stoptime.rb - The Stop… Camping Time! time registration and invoice
#               application.
#
# Stop… Camping Time! is Copyright © 2011 Paul van Tilburg <paul@luon.net>
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.

require "active_support"
require "camping"
require "markaby"
require "pathname"

Markaby::Builder.set(:indent, 2)
Camping.goes :StopTime

unless defined? BASE_DIR
  BASE_DIR = Pathname.new(__FILE__).dirname.expand_path + "public"

  # Set the default date(/time) format.
  ActiveSupport::CoreExtensions::Time::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d %H:%M",
    :month_and_year => "%B %Y",
    :month_code => "%Y%m")
  ActiveSupport::CoreExtensions::Date::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d",
    :month_and_year => "%B %Y")

  # FIXME: this should be configurable.
  HourlyRate = 20.00
end


module StopTime

  def self.create
    StopTime::Models.create_schema
  end

end

module StopTime::Models

  class Customer < Base
    has_many :tasks
    has_many :time_entries, :through => :tasks

    def task_summary(month)
      # FIXME: ensure that month is a DateTime/Time object.
      time_entries = self.time_entries.all(:conditions => 
        ["start > ? AND end < ?", month, month.at_end_of_month])

      tasks = time_entries.inject({}) do |tasks, entry|
        time = (entry.end - entry.start)/1.hour
        if tasks.has_key? entry.task
          tasks[entry.task][0] += time
          tasks[entry.task][2] += time * HourlyRate
        else
          tasks[entry.task] = [time, HourlyRate, time * HourlyRate]
        end
        tasks
      end

      return tasks
    end
  end

  class Task < Base
    has_many :time_entries
    belongs_to :customer
  end

  class TimeEntry < Base
    belongs_to :task
    
  end

  class StopTimeTables < V 1.0
    def self.up
      create_table Customer.table_name do |t|
        t.string :name, :short_name, 
          :address_street, :address_postal_code, :address_city,
          :email, :phone
        t.timestamps
      end
      create_table Task.table_name do |t|
        t.integer :customer_id
        t.string :name
        t.timestamps
      end
      create_table TimeEntry.table_name do |t|
        t.integer :task_id
        t.datetime :start, :end
        t.timestamps
      end
    end

    def self.down
      drop_table Customer.table_name
      drop_table Task.table_name
      drop_table TimeEntry.table_name
    end
  end

end # module StopTime::Models

module StopTime::Controllers

  class Index
    def get
      redirect R(Timereg)
    end
  end

  class Customers
    def get
      @customers = Customer.all
      render :customers
    end

    def post
      return redirect R(Customers) if @input.cancel
      @customer = Customer.create(
        :name => @input.name,
        :short_name => @input.short_name,
        :address_street => @input.address_street,
        :address_postal_code => @input.address_postal_code,
        :address_city => @input.address_city,
        :email => @input.email,
        :phone => @input.phone)
      @customer.save
      if @customer.invalid?
        @errors = @customer.errors
        return render :customer_new
      end
      redirect R(Customers)
    end
  end

  class CustomersNew
    def get
      render :customer_form
    end
  end

  class CustomersN
    def get(customer_id)
      @customer = Customer.find(customer_id)
      render :customer_form
    end

    def post(customer_id)
      return redirect R(Customers) if @input.cancel
      @customer = Customer.find(customer_id)
      if @input.has_key? "delete"
        @customer.delete
      elsif @input.has_key? "save"
        attrs = ["name", "short_name",
                 "address_street", "address_postal_code", "address_city",
                 "email", "phone"]
        attrs.each do |attr|
          @customer[attr] = @input[attr] unless @input[attr].blank?
        end
        @customer.save
        if @customer.invalid?
          @errors = @customer.errors
          return render :customer_form
        end
      end
      redirect R(Customers)
    end
  end

  class CustomersNTasks
    def post(customer_id)
      if @input.has_key? "add"
        @task = Task.create(
          :customer_id => customer_id,
          :name => @input.new_task)
        @task.save
        if @task.invalid?
          @errors = @task.errors
        end
      elsif @input.has_key? "delete"
        @input.tasks.each { |task_id| Task.find(task_id).delete }
      end
      redirect R(CustomersN, customer_id)
    end
  end

  class CustomersNInvoicesX
    def get(customer_id, number)
      @month = DateTime.new(number[0..3].to_i, number[4..5].to_i, 1)
      @number = number[5..-1].to_i

      @customer = Customer.find(customer_id)
      @tasks = @customer.task_summary(@month)

      render :invoice
    end
  end

  class Timereg
    def get
      @time_entries = TimeEntry.all(:order => "start DESC")
      @customer_list = Customer.all.map { |c| [c.id, c.short_name] }
      @task_list = Task.all.map { |t| [t.id, t.name] }
      render :time_entries
    end

    def post
      if @input.has_key? "enter"
        @entry = TimeEntry.create(
          :task_id => @input.task,
          :start => @input.start,
          :end => @input.end)
        @entry.save
        if @entry.invalid?
          @errors = @entry.errors
        end
      elsif @input.has_key? "delete"
      end

      @time_entries = TimeEntry.all(:order => "start DESC")
      @customer_list = Customer.all.map { |c| [c.id, c.short_name] }
      @task_list = Task.all.map { |t| [t.id, t.name] }
      render :time_entries
    end
  end

  class TimeregN
    def post(entry_id)
      TimeEntry.find(entry_id).delete
      redirect R(Timereg)
    end
  end

  class Invoices
    def get
      @time_entries = TimeEntry.all(:order => "start ASC")
      @customers = Hash.new { |h, k| h[k] = Array.new }

      @time_entries.each do |e|
        month = e.start.at_beginning_of_month
        customer = e.task.customer
        unless @customers[month].include? customer
          @customers[month] << customer
        end
      end
      render :invoices
    end
  end
  
end # module StopTime::Controllers

module StopTime::Views

  def layout
    xhtml_strict do
      head do
        title "Stop… Camping Time!"
      end
      body do
        div.wrapper! do
          h1 "Stop… Camping Time!"
          _menu
          div.content! do
            self << yield
          end
        end
      end
    end
  end

  def _menu
    ol.menu! do
      li { a "Time Registration", :href => R(Timereg) }
      li { a "Customers", :href => R(Customers) }
      li { a "Invoices", :href => R(Invoices) }
    end
  end

  def time_entries
    h2 "List of time entries"
    table do
      tr do
        th "Customer"
        th "Project/task"
        th "Start time"
        th "End time"
        th "Total"
      end
      form :action => R(Timereg), :method => :post do
        tr do
          td { _form_select("customer", @customer_list) }
          td { _form_select("task", @task_list) }
          td { input :type => :text, :name => "start", 
                     :value => DateTime.now.to_date.to_formatted_s + " " }
          td { input :type => :text, :name => "end",
                     :value => DateTime.now.to_date.to_formatted_s + " " }
          td { "N/A" }
          td do
            input :type => :submit, :name => "enter", :value => "Enter"
            input :type => :reset,  :name => "clear", :value => "Clear"
          end
        end
      end
      @time_entries.each do |entry|
        tr do
          td { entry.task.customer.short_name }
          td { entry.task.name }
          td { entry.start }
          td { entry.end }
          td { "%.2fh" % ((entry.end - entry.start)/3600.0) }
          td do
            form :action => R(TimeregN, entry.id), :method => :post do
              input :type => :submit, :name => "delete", :value => "Delete"
            end
          end
        end
      end
    end
  end

  def customers
    h2 "List of customers"
    table do
       tr do
         th "Name"
         th "Short name"
         th "Address"
         th "Email"
         th "Phone"
       end
      @customers.each do |customer|
        tr do
          td { customer.name }
          td { customer.short_name }
          td { [customer.address_street,
                customer.address_postal_code,
                customer.address_city].join(", ") unless customer.address_street.blank? }
          td { customer.email }
          td { customer.phone }
          td do 
            form :action => R(CustomersN, customer.id), :method => :get do
              input :type => :submit, :value => "Edit"
            end
            form :action => R(CustomersN, customer.id), :method => :post do
              input :type => :submit, :name => "delete", :value => "Delete"
            end
          end
        end
      end
    end
    p do
      a "Add a new customer", :href=> R(CustomersNew)
    end
  end
  
  def customer_form
    if @customer
      @edit_task = true
      target = [CustomersN, @customer.id]
    else
      @customer = {}
      target = [Customers]
    end
    form :action => R(*target), :method => :post do
      ol do 
        li { _form_input(@customer, "Name", "name", :text) }
        li { _form_input(@customer, "Short name", "short_name", :text) }
        li { _form_input(@customer, "Street address", "address_street", :text) }
        li { _form_input(@customer, "Postal code", "address_postal_code", :text) }
        li { _form_input(@customer, "City/town", "address_city", :text) }
        li { _form_input(@customer, "Email address", "email", :text) }
        li { _form_input(@customer, "Phone number", "phone", :text) }
      end
      input :type => "submit", :name => "save", :value => "Save"
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
    if @edit_task
      form :action => R(CustomersNTasks, @customer.id), :method => :post do
        h2 "Projects & Tasks"
        select :name => "tasks[]", :multiple => "multiple", :size => 6 do
          @customer.tasks.each do |task|
            option(:value => task.id) { task.name }
          end
        end
        input :type => :text, :name => "new_task"
        input :type => :submit, :name => "add", :value => "Add"
        input :type => :submit, :name => "delete", :value => "Delete"
      end
    end
  end

  def invoices
    h2 "List of invoices"

    cmonth = Time.now
    @customers.each do |month, custs|
      unless month == cmonth
        h3 { month.to_formatted_s(:month_and_year) }
        cmonth = month
      end
      ol do
        custs.each do |cust|
          li do 
            span { cust.name }
            a "view", :href => R(CustomersNInvoicesX,
                                 cust.id, month.to_formatted_s(:month_code))
          end
        end
      end
    end
  end

  def invoice
    h2 { "Invoice for #{@customer.name}, month
          #{@month.to_formatted_s(:month_and_year)}" }
    
    table do
      tr do
        th { "Description" }
        th { "Number of hours" }
        th { "Hourly rate" }
        th { "Amount" }
      end
      total = 0.0
      @tasks.each do |task, line|
        tr do
          td { task.name }
          td { "%.2fh" % line[0] }
          td { "€ %.2f" % line[1] }
          td { "€ %.2f" % line[2] }
        end
        total += line[2]
      end
      tr do
        td { b "Total amount" }
        td ""
        td ""
        td { "€ %.2f" % total }
      end
    end
  end

  def _form_input(obj, label_name, input_name, type, options={})
    label label_name, :for => input_name
    input :type => type, :name => input_name, :id => input_name,
          :value => @input[input_name] || obj[input_name]
  end

  def _form_select(name, options) 
    select :name => name, :id => name do
      options.each do |opt_val, opt_str|
        if opt_val == @input[name]
          option(:value => opt_val, :selected => "true") { opt_str }
        else
          option(:value => opt_val) { opt_str }
        end
      end
    end
  end

end # module StopTime::Views
