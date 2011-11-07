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
require "mime/types"
require "pathname"

Markaby::Builder.set(:indent, 2)
Camping.goes :StopTime

unless defined? PUBLIC_DIR
  PUBLIC_DIR = Pathname.new(__FILE__).dirname.expand_path + "public"
  TEMPLATE_DIR = Pathname.new(__FILE__).dirname.expand_path + "templates"

  # Set the default date(/time) format.
  ActiveSupport::CoreExtensions::Time::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d %H:%M",
    :month_and_year => "%B %Y",
    :month_code => "%Y%m",
    :day_code => "%Y%m%d")
  ActiveSupport::CoreExtensions::Date::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d",
    :month_and_year => "%B %Y")

  # FIXME: this should be configurable.
  HourlyRate = 20.0
  VATRate = 19.0
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
  end

  class Task < Base
    has_many :time_entries
    belongs_to :customer

    def fixed_cost?
      not self.fixed_cost.blank?
    end

    def task_type
      fixed_cost? ? "fixed_cost" : "hourly_rate"
    end
  end

  class TimeEntry < Base
    belongs_to :task
    belongs_to :invoice
    has_one :customer, :through => :task

    def total
      (self.end - self.start) / 1.hour
    end
  end

  class Invoice < Base
    has_many :time_entries
    belongs_to :customer

    def summary
      # FIXME: ensure that month is a DateTime/Time object.
      time_entries = self.time_entries.all

      tasks = time_entries.inject({}) do |tasks, entry|
        time = entry.total
        if tasks.has_key? entry.task
          tasks[entry.task][0] += time
          tasks[entry.task][2] += time * entry.task.hourly_rate
        else
          tasks[entry.task] = [time, entry.task.hourly_rate, 
                                     time * entry.task.hourly_rate]
        end
        tasks
      end

      return tasks
    end
  end

  class CompanyInfo < Base
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
        t.integer :task_id, :invoice_id
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

  class CommentSupport < V 1.1
    def self.up
      add_column(TimeEntry.table_name, :comment, :string)
    end

    def self.down
      remove_column(TimeEntry.table_name, :comment)
    end
  end

  class BilledFlagSupport < V 1.2
    def self.up
      add_column(TimeEntry.table_name, :bill, :boolean)
    end

    def self.down
      remove_column(TimeEntry.table_name, :bill)
    end
  end

  class HourlyRateSupport < V 1.3
    def self.up
      add_column(Customer.table_name, :hourly_rate, :float,
                                      :null => false, :default => HourlyRate)
    end

    def self.down
      remove_column(Customer.table_name, :hourly_rate)
    end
  end

  class FixedCostTaskSupport < V 1.4
    def self.up
      add_column(Task.table_name, :billed, :boolean)
      add_column(Task.table_name, :fixed_cost, :float)
      add_column(Task.table_name, :hourly_rate, :float)
    end

    def self.down
      remove_column(Task.table_name, :billed)
      remove_column(Task.table_name, :fixed_cost)
      remove_column(Task.table_name, :hourly_rate, :float)
    end
  end

  class InvoiceSupport < V 1.5
    def self.up
      create_table Invoice.table_name do |t|
        t.integer :number, :customer_id
        t.boolean :payed
        t.timestamps
      end
      add_column(TimeEntry.table_name, :invoice_id, :integer)
    end

    def self.down
      drop_table Invoice.table_name
      remove_column(TimeEntry.table_name, :invoice_id)
    end
  end

  class CompanyInfoSupport < V 1.6
    def self.up
      create_table CompanyInfo.table_name do |t|
        t.string :name, :contact_name,
                 :address_street, :address_postal_code, :address_city,
                 :country, :country_code,
                 :phone, :cell, :email, :website,
                 :chamber, :vatno, :accountname, :accountno
        t.timestamps
     end

     # Add company info record with defaults.
     cinfo = CompanyInfo.create(:name => "My Company",
                                :contact_name => "Me",
                                :country => "The Netherlands",
                                :country_code => "NL")
     cinfo.save
   end

   def self.down
     drop_table CompanyInfo.table_name
   end
  end

end # StopTime::Models

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
        :phone => @input.phone,
        :hourly_rate => @input.hourly_rate)
      @customer.save
      if @customer.invalid?
        @errors = @customer.errors
        return render :customer_form
      end
      redirect R(Customers)
    end
  end

  class CustomersNew
    def get
      # FIXME: set other defaults?
      @customer = Customer.new(:hourly_rate => HourlyRate)
      @target = [Customers]
      render :customer_form
    end
  end

  class CustomersN
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @edit_task = true
      @target = [CustomersN, @customer.id]
      @input = @customer.attributes
      render :customer_form
    end

    def post(customer_id)
      return redirect R(Customers) if @input.cancel
      @customer = Customer.find(customer_id)
      if @input.has_key? "delete"
        @customer.delete
      elsif @input.has_key? "update"
        attrs = ["name", "short_name",
                 "address_street", "address_postal_code", "address_city",
                 "email", "phone", "hourly_rate"]
        attrs.each do |attr|
          @customer[attr] = @input[attr]
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
      if @input.has_key? "delete"
        @task = Task.find(@input.task_id)
        @task.delete
      elsif @input.has_key? "edit"
        return redirect R(CustomersNTasksN, customer_id, @input.task_id)
      else
        @task = Task.create(
          :customer_id => customer_id,
          :name => @input.name)
        case @input.task_type
        when "fixed_cost"
          @task.fixed_cost = @input.fixed_cost
          @task.hourly_rate = nil
        when "hourly_rate"
          @task.fixed_cost = nil
          @task.hourly_rate = @input.hourly_rate
        # FIXME: catch invalid task types!
        end
        @task.save
        if @task.invalid?
          @errors = @task.errors
          @customer = Customer.find(customer_id)
          @target = [CustomersNTasks, customer_id]
          @method = "create"
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end

  class CustomersNTasksNew
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @task = Task.new(:hourly_rate => @customer.hourly_rate)
      @target = [CustomersNTasks, customer_id]
      @method = "create"
      @input = @task.attributes
      @input["task_type"] = @task.task_type # FIXME: find nicer way!
      render :task_form
    end
  end

  class CustomersNTasksN
    def get(customer_id, task_id)
      @customer = Customer.find(customer_id)
      @task = Task.find(task_id)
      @target = [CustomersNTasksN,  customer_id, task_id]
      @method = "update"
      @input = @task.attributes
      @input["task_type"] = @task.task_type
      # FIXME: Check that task is of that customer.
      render :task_form
    end

    def post(customer_id, task_id)
      return redirect R(CustomersN, customer_id) if @input.cancel
      @customer = Customer.find(customer_id)
      @task = Task.find(task_id)
      if @input.has_key? "update"
        # FIXME: task should be cloned/dupped as to prevent rewriting history!
        @task["name"] = @input["name"] unless @input["name"].blank?
        case @input.task_type
        when "fixed_cost"
          @task.fixed_cost = @input.fixed_cost
          @task.hourly_rate = nil
        when "hourly_rate"
          @task.fixed_cost = nil
          @task.hourly_rate = @input.hourly_rate
        end
        @task["billed"] = @input.has_key? "billed"
        @task.save
        if @task.invalid?
          @errors = @task.errors
          @target = [CustomersNTasksN,  customer_id, task_id]
          @method = "update"
          @input = @task.attributes
          @input["task_type"] = @input.task_type
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end

  class CustomersNInvoicesX
    def get(customer_id, invoice_id)
      @month = DateTime.new(invoice_id[0..3].to_i, invoice_id[4..5].to_i, 1)
      @number = invoice_id[6..-1]
      # FIXME: make this (much) nicer!
      invoice_id.gsub!(/\.pdf$/, '')
      if m = @number.match(/(\d+)\.(\w+)$/)
        @number = m[1].to_i
        @format = m[2]
      else
        @number = @number.to_i
        @format = "html"
      end

      @company = CompanyInfo.first
      @customer = Customer.find(customer_id)
      @tasks = @customer.task_summary(@month)

      if @format == "html"
        render :invoice
      elsif @format == "pdf"
        pdf_file = PUBLIC_DIR + "#{invoice_id}.pdf"
        unless pdf_file.exist?
          _generate_invoice_pdf(@customer, @tasks, @month, invoice_id)
        end
        redirect(StaticX, pdf_file.basename)
      end
    end

    def _generate_invoice_pdf(customer, tasks, month, invoice_id)
      template = TEMPLATE_DIR + "invoice.tex.erb"
      tex_file = PUBLIC_DIR + "#{invoice_id}.tex"

      erb = ERB.new(File.read(template))
      File.open(tex_file, "w") { |f| f.write(erb.result(binding)) }
      system("rubber --pdf --inplace #{tex_file}")
      system("rubber --clean --inplace #{tex_file}")
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
          :end => @input.end,
          :comment => @input.comment,
          :bill => @input.has_key?("bill"))
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

  class Company
    def get
      @company = CompanyInfo.first
      @input = @company.attributes
      render :company_form
    end

    def post
      @company = CompanyInfo.first
      attrs = ["name", "contact_name",
               "address_street", "address_postal_code", "address_city",
               "country", "country_code",
               "phone", "cell", "email", "website",
               "chamber", "vatno", "accountname", "accountno"]
      attrs.each do |attr|
        @company[attr] = @input[attr]
      end
      @company.save
      if @company.invalid?
        @errors = @company.errors
      end
      render :company_form
    end
  end

  class StaticX
    def get(path)
      mime_type = MIME::Types.type_for(path).first
      @headers['Content-Type'] = mime_type.nil? ? "text/plain" : mime_type.to_s
      unless path.include? ".."
        @headers['X-Sendfile'] = (PUBLIC_DIR + path).to_s
      else
        @status = "403"
        "Error 403: Invalid path: #{path}"
      end
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
      li { a "Overview", :href => R(Index) }
      li { a "Time Registration", :href => R(Timereg) }
      li { a "Customers", :href => R(Customers) }
      li { a "Invoices", :href => R(Invoices) }
      li { a "Company", :href => R(Company) }
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
        th "Comment"
        th "Total time"
        th "Bill?"
      end
      form :action => R(Timereg), :method => :post do
        tr do
          td { _form_select("customer", @customer_list) }
          td { _form_select("task", @task_list) }
          td { input :type => :text, :name => "start", 
                     :value => DateTime.now.to_date.to_formatted_s + " " }
          td { input :type => :text, :name => "end",
                     :value => DateTime.now.to_date.to_formatted_s + " " }
          td { input :type => :text, :name => "comment" }
          td { "N/A" }
          td { _form_input_checkbox("bill") }
          td do
            input :type => :submit, :name => "enter", :value => "Enter"
            input :type => :reset,  :name => "clear", :value => "Clear"
          end
        end
      end
      @entries.each do |entry|
        tr do
          td { a entry.customer.short_name, 
                 :href => R(CustomersN, entry.customer.id) }
          td { a entry.task.name,
                 :href => R(CustomersNTasksN, entry.customer.id, entry.task.id) }
          td { a entry.start,
                 :href => R(TimeregN, entry.id) }
          td { entry.end }
          td { entry.comment }
          td { "%.2fh" % entry.total }
          td do 
            if entry.bill
              input :type => "checkbox", :name => "bill_#{entry.id}",
                    :checked => true, :disabled => true
            else
              input :type => "checkbox", :name => "bill_#{entry.id}",
                    :disabled => true
            end
          end
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
          td { a customer.name, :href => R(CustomersN, customer.id) }
          td { customer.short_name }
          td { [customer.address_street,
                customer.address_postal_code,
                customer.address_city].join(", ") unless customer.address_street.blank? }
          td { a customer.email, :href => "mailto:#{customer.email}" }
          td { customer.phone }
          td do 
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
    form :action => R(*@target), :method => :post do
      ol do 
        li { _form_input_with_label("Name", "name", :text) }
        li { _form_input_with_label("Short name", "short_name", :text) }
        li { _form_input_with_label("Street address", "address_street", :text) }
        li { _form_input_with_label("Postal code", "address_postal_code", :text) }
        li { _form_input_with_label("City/town", "address_city", :text) }
        li { _form_input_with_label("Email address", "email", :text) }
        li { _form_input_with_label("Phone number", "phone", :text) }
        li { _form_input_with_label("Hourly rate", "hourly_rate", :text) }
      end
      input :type => "submit", :name => "update", :value => "Update"
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
    if @edit_task
      # FXIME: the following is not very RESTful!
      form :action => R(CustomersNTasks, @customer.id), :method => :post do
        h2 "Projects & Tasks"
        select :name => "task_id", :size => 6 do
          @customer.tasks.each do |task|
            option(:value => task.id) { task.name }
          end
        end
        input :type => :submit, :name => "edit", :value => "Edit"
        input :type => :submit, :name => "delete", :value => "Delete"
      end
      a "Add a new project/task", :href => R(CustomersNTasksNew, @customer.id)
    end
  end

  def task_form
    # FIXME: it's not always new
    h2 "New task for #{@customer.name}"

    form :action => R(*@target), :method => :post do
      ul do 
        li { _form_input_with_label("Name", "name", :text) }
        li do
          ol.radio do
            li do 
              _form_input_radio("task_type", "hourly_rate", default=true)
              _form_input_with_label("Hourly rate", "hourly_rate", :text)
            end
            li do
              _form_input_radio("task_type", "fixed_cost")
              _form_input_with_label("Fixed cost", "fixed_cost", :text)
            end
          end
        end 
        li do 
          _form_input_checkbox("billed")
          label "Billed!", :for => "billed"
        end
      end
      input :type => "submit", :name => @method, :value => @method.capitalize
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
  end

  def invoices
    h2 "List of invoices"

    cmonth = Time.now
    ccnt = 1
    @customers.each do |month, custs|
      unless month == cmonth
        h3 { month.to_formatted_s(:month_and_year) }
        cmonth = month
        ccnt = 1
      end
      ol do
        custs.each do |cust|
          li do 
            span { cust.name }
            a "view", :href => R(CustomersNInvoicesX,
                                 cust.id, month.to_formatted_s(:month_code) +
                                          "%02d" % ccnt)
          end
          ccnt = ccnt + 1
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
      subtotal = 0.0
      @tasks.each do |task, line|
        tr do
          td { task.name }
          td { "%.2fh" % line[0] }
          td { "€ %.2f" % line[1] }
          td { "€ %.2f" % line[2] }
        end
        subtotal += line[2]
      end
      tr do
        td { i "Sub-total" }
        td ""
        td ""
        td { "€ %.2f" % subtotal }
      end
      vat = subtotal * VATRate/100
      tr do
        td { i "VAT #{VATRate}%" }
        td ""
        td ""
        td { "€ %.2f" % vat }
      end
      tr do
        td { b "Total amount" }
        td ""
        td ""
        td { "€ %.2f" % (subtotal + vat) }
      end
    end
  end

  def company_form
    h2 "Company Information"

    if @errors
      div.form_errors do
        h3 "There were #{@errors.count} errors in the form!"
        ul do
          @errors.each do |attrib, msg|
            li "#{attrib.to_s.capitalize} #{msg}"
          end
        end
      end
    end
    form :action => R(Company), :method => :post do
      ol do 
        li { _form_input_with_label("Name", "name", :text) }
        li { _form_input_with_label("Contact name", "contact_name", :text) }
        li { _form_input_with_label("Street address", "address_street", :text) }
        li { _form_input_with_label("Postal code", "address_postal_code", :text) }
        li { _form_input_with_label("City/town", "address_city", :text) }
        li { _form_input_with_label("Phone number", "phone", :text) }
        li { _form_input_with_label("Cellular number", "cell", :text) }
        li { _form_input_with_label("Email address", "email", :text) }
        li { _form_input_with_label("Web address", "website", :text) }
        li { _form_input_with_label("Chamber number", "chamber", :text) }
        li { _form_input_with_label("VAT number", "vatno", :text) }
        li { _form_input_with_label("Account name", "accountname", :text) }
        li { _form_input_with_label("Account number", "accountno", :text) }
      end
      input :type => "submit", :name => "update", :value => "Update"
    end
  end

  def _form_input_with_label(label_name, input_name, type)
    label label_name, :for => input_name
    input :type => type, :name => input_name, :id => input_name,
          :value => @input[input_name]
  end

  def _form_input_radio(name, value, default=false)
    input_val = @input[name]
    if input_val == value or (input_val.blank? and default)
      input :type => "radio", :id => "#{name}_#{value}",
            :name => name, :value => value, :checked => true
    else
      input :type => "radio", :id => "#{name}_#{value}",
            :name => name, :value => value
    end
  end

  def _form_input_checkbox(name, value=true)
    if @input[name] == value
      input :type => "checkbox", :id => "#{name}_#{value}", :name => name,
            :value => value, :checked => true
    else
      input :type => "checkbox", :id => "#{name}_#{value}", :name => name, 
            :value => value
    end
  end

  def _form_select(name, opts_list) 
    select :name => name, :id => name do
      opts_list.each do |opt_val, opt_str|
        if @input[name] == opt_val
          option opt_str, :value => opt_val, :selected => true
        else
          option opt_str, :value => opt_val
        end
      end
    end
  end

end # module StopTime::Views
