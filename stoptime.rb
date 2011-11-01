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
    :default => "%Y-%m-%d %H:%M")
  ActiveSupport::CoreExtensions::Date::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d")
end

module StopTime

  def self.create
    StopTime::Models.create_schema
  end

end

module StopTime::Models

  class Customer < Base
    has_many :tasks
  end

  class Task < Base
    has_many :time_entries
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
      render :overview
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

  class Tasks
    def get
      @tasks = Tasks.all
      render :tasks
    end
  end

  class TimeEntries
    def get
      @time_entries = TimeEntry.all
      render :time_entries
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
          self << yield
        end
      end
    end
  end

  def customers
  end

  def overview
    h1 "Stop… Camping Time!"

    p "You can check out:"
    ul do
      li { a "Customers", :href => R(Customers) }
      li { a "Task", :href=> R(Tasks) }
      li { a "Time entries", :href => R(TimeEntries) }
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
