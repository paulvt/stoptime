#!/usr/bin/env camping
#
# stoptime.rb - The Stop… Camping Time! time registration and invoicing application.
#
# Stop… Camping Time! is Copyright © 2011 Paul van Tilburg <paul@luon.net>
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.

require "action_view"
require "active_support"
require "camping"
require "markaby"
require "pathname"
require "sass/plugin/rack"

Markaby::Builder.set(:indent, 2)
Camping.goes :StopTime

unless defined? PUBLIC_DIR
  # The directory with public data.
  PUBLIC_DIR = Pathname.new(__FILE__).dirname.expand_path + "public"
  # The directory with template data.
  TEMPLATE_DIR = Pathname.new(__FILE__).dirname.expand_path + "templates"

  # Set up the locales.
  I18n.load_path += Dir[ File.join('locale', '*.yml') ]

  # Set up SASS.
  Sass::Plugin.options[:template_location] = "templates/sass"

  # Set the default date(/time) format.
  ActiveSupport::CoreExtensions::Time::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d %H:%M",
    :month_and_year => "%B %Y",
    :date_only => "%Y-%m-%d",
    :time_only => "%H:%M",
    :day_code => "%Y%m%d")
  ActiveSupport::CoreExtensions::Date::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d",
    :month_and_year => "%B %Y")

  # The default hourly rate.
  # FIXME: this should be configurable.
  HourlyRate = 20.0

  # The default VAT rate.
  VATRate = 19
end

# = The main application module
module StopTime

  # Enable SASS CSS generation from templates/sass.
  use Sass::Plugin::Rack

  # Create/migrate the database when needed.
  def self.create
    StopTime::Models.create_schema
  end

end

# = The Stop… Camping Time! models
module StopTime::Models

  # == The customer class
  #
  # This class represents a customer that has projects/tasks
  # for which invoices need to be generated.
  #
  # === Attributes
  #
  # [id] unique identification number (Fixnum)
  # [name] official (long) name (String)
  # [short_name] abbreviated name (String)
  # [address_street] street part of the address (String)
  # [address_postal_code] zip/postal code part of the address (String)
  # [address_city] city part of the postal code (String)
  # [email] email address (String)
  # [phone] phone number (String)
  # [hourly_rate] default hourly rate (Float)
  # [created_at] time of creation (Time)
  # [updated_at] time of last update (Time)
  #
  # === Attributes by association
  #
  # [invoices] list of invoices (Array of Invoice)
  # [tasks] list of tasks (Array of Task)
  # [time_entries] list of time entries (Array of TimeEntry)
  class Customer < Base
    has_many :tasks
    has_many :invoices
    has_many :time_entries, :through => :tasks

    # Returns a list of tasks that have not been billed via in invoice.
    def unbilled_tasks
      tasks.all(:conditions => ["invoice_id IS NULL"])
    end
  end

  # == The task class
  #
  # This class represents a task (or project) of a customer on which time can
  # be registered.
  # There are two types of classes:  with an hourly and with a fixed cost.
  #
  # === Attributes
  #
  # [id] unique identification number (Fixnum)
  # [name] description (String)
  # [fixed_cost] fixed cost of the task (Float)
  # [hourly_rate] hourly rate for the task (Float)
  # [created_at] time of creation (Time)
  # [updated_at] time of last update (Time)
  #
  # === Attributes by association
  #
  # [customer] associated customer (Customer)
  # [invoice] associated invoice if the task is billed (Invoice)
  # [time_entries] list of registered time entries (Array of TimeEntry)
  class Task < Base
    has_many :time_entries
    belongs_to :customer
    belongs_to :invoice

    # Determines whether the task has a fixed cost.
    # When +false+ is returned, one can assume the task has an hourly rate.
    def fixed_cost?
      not self.fixed_cost.blank?
    end

    # Returns the type of the task, this is a String valued either
    # "+fixed_cost+" or "+hourly_rate+".
    def type
      fixed_cost? ? "fixed_cost" : "hourly_rate"
    end

    # Returns a list of time entries that should be (and are not yet)
    # billed.
    def billable_time_entries
      time_entries.all(:conditions => ["bill = 't'"], :order => "start ASC")
    end

    # Returns the bill period of the task by means of an Array containing
    # the first and last Time object found for registered time on this
    # task.
    # If no time is registered, the last time the task has been updated
    # is returned.
    def bill_period
      bte = billable_time_entries
      if bte.empty?
        # FIXME: better defaults?
        [updated_at, updated_at]
      else
        [bte.first.start, bte.last.end]
      end
    end

    # Returns whether the task is billed, i.e. included in an invoice.
    def billed?
      not invoice.nil?
    end

    # Returns a time and cost summary of the registered time on the task
    # by means of Array of three values.
    # In case of a fixed cost task, only the third value is set to the
    # fixed cost.
    # In case of a task with an hourly rate, the first value is
    # the total of time (in hours), the second value is the hourly rate,
    # and the third value is the total amount (time times rate).
    def summary
      case type
      when "fixed_cost"
        [nil, nil, fixed_cost]
      when "hourly_rate"
        time_entries.inject([0.0, hourly_rate, 0.0]) do |summ, te|
          summ[0] += te.hours_total
          summ[2] += te.hours_total * hourly_rate
          summ
        end
      end
    end
  end

  # == The time entry class
  #
  # This class represents an amount of time that is registered on a certain
  # task.
  #
  # === Attributes
  #
  # [id] unique identification number (Fixnum)
  # [date] date of the entry (Time)
  # [start] start time of the entry (Time)
  # [end] finish time of the entry (Time)
  # [bill] flag whether to bill or not (FalseClass/TrueClass)
  # [comment] additional comment (String)
  # [created_at] time of creation (Time)
  # [updated_at] time of last update (Time)
  #
  # === Attributes by association
  #
  # [task] task the entry registers time for (Task)
  # [customer] associated customer (Customer)
  class TimeEntry < Base
    belongs_to :task
    has_one :customer, :through => :task

    # Returns the total amount of time, the duration, in hours.
    def hours_total
      (self.end - self.start) / 1.hour
    end
  end

  # == The invoice class
  #
  # This class represents an invoice for a customer that contains billed
  # tasks and through the tasks registered time.
  #
  # === Attributes
  #
  # [id] unique identification number (Fixnum)
  # [number] invoice number (Fixnum)
  # [paid] flag whether the invoice has been paid (TrueClass/FalseClass)
  # [created_at] time of creation (Time)
  # [updated_at] time of last update (Time)
  #
  # === Attributes by association
  #
  # [customer] associated customer (Customer)
  # [tasks] billed tasks by the invoice (Array of Task)
  # [time_entries] billed time entries (Array of TimeEntry)
  class Invoice < Base
    has_many :tasks
    has_many :time_entries, :through => :tasks
    belongs_to :customer

    # Returns a a time and cost summary of the contained tasks.
    # See also Task#summary.
    def summary
      summ = {}
      tasks.each { |task| summ[task.name] = task.summary }
      return summ
    end

    # Returns the invoice period based on the contained tasks.
    # See also Task#bill_period.
    def period
      # FIXME: maybe should be updated_at?
      return [created_at, created_at] if tasks.empty?
      p = tasks.first.bill_period
      tasks.each do |task|
        tp = task.bill_period
        p[0] = tp[0] if tp[0] < p[0]
        p[1] = tp[1] if tp[1] > p[1]
      end
      return p
    end
  end

  # == The company information class
  #
  # This class contains information about the company or sole
  # proprietorship of the user of Stop… Camping Time!
  #
  # === Attributes
  #
  # [id] unique identification number (Fixnum)
  # [name] official company name (String)
  # [contact_name] optional personal contact name (String)
  # [address_street] street part of the address (String)
  # [address_postal_code] zip/postal code part of the address (String)
  # [address_city] city part of the postal code (String)
  # [country] country of residence (String)
  # [country_code] two letter country code (String)
  # [email] email address (String)
  # [phone] phone number (String)
  # [cell] cellular phone number (String)
  # [website] web address (String)
  # [chamber] optional chamber of commerce ID number (String)
  # [vatno] optional VAT number (String)
  # [accountname] name of the bank account holder (String)
  # [accountno] number of the bank account (String)
  # [created_at] time of creation (Time)
  # [updated_at] time of last update (Time)
  class CompanyInfo < Base
  end

  class StopTimeTables < V 1.0 # :nodoc:
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

  class CommentSupport < V 1.1 # :nodoc:
    def self.up
      add_column(TimeEntry.table_name, :comment, :string)
    end

    def self.down
      remove_column(TimeEntry.table_name, :comment)
    end
  end

  class BilledFlagSupport < V 1.2 # :nodoc:
    def self.up
      add_column(TimeEntry.table_name, :bill, :boolean)
    end

    def self.down
      remove_column(TimeEntry.table_name, :bill)
    end
  end

  class HourlyRateSupport < V 1.3 # :nodoc:
    def self.up
      add_column(Customer.table_name, :hourly_rate, :float,
                                      :null => false, :default => HourlyRate)
    end

    def self.down
      remove_column(Customer.table_name, :hourly_rate)
    end
  end

  class FixedCostTaskSupport < V 1.4 # :nodoc:
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

  class InvoiceSupport < V 1.5 # :nodoc:
    def self.up
      create_table Invoice.table_name do |t|
        t.integer :number, :customer_id
        t.boolean :payed
        t.timestamps
      end
    end

    def self.down
      drop_table Invoice.table_name
    end
  end

  class CompanyInfoSupport < V 1.6 # :nodoc:
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

  class ImprovedInvoiceSupport < V 1.7 # :nodoc:
    def self.up
      add_column(Task.table_name, :invoice_id, :integer)
      remove_column(Task.table_name, :billed)
      remove_column(TimeEntry.table_name, :invoice_id)
    end

    def self.down
      remove_column(Task.table_name, :invoice_id, :integer)
      add_column(Task.table_name, :billed, :boolean)
      add_column(TimeEntry.table_name, :invoice_id)
    end
  end

  class TimeEntryDateSupport < V 1.8 # :nodoc:
    def self.up
      add_column(TimeEntry.table_name, :date, :datetime)
      TimeEntry.all.each do |te|
        te.date = te.start.at_beginning_of_day
        te.save
      end
    end

    def self.down
      remove_column(TimeEntry.table_name, :date)
    end
  end

  class PaidFlagTypoFix < V 1.9 # :nodoc:
    def self.up
      add_column(Invoice.table_name, :paid, :boolean)
      Invoice.all.each do |i|
        i.paid = i.payed unless i.payed.blank?
        i.save
      end
      remove_column(Invoice.table_name, :payed)
    end

    def self.down
      add_column(Invoice.table_name, :payed, :boolean)
      Invoice.all.each do |i|
        i.payed = i.paid unless i.paid.blank?
        i.save
      end
      remove_column(Invoice.table_name, :paid)
    end
  end

end # StopTime::Models

# = The Stop… Camping Time! controllers
module StopTime::Controllers

  # == The index controller
  #
  # Controller that presents the overview as the index, listing
  # the running tasks and projects per customer.
  #
  # path:: /
  # view:: Views#overview
  class Index
    def get
      @tasks = {}
      Customer.all.each do |customer|
        @tasks[customer] = customer.unbilled_tasks.sort_by { |t| t.name }
      end
      render :overview
    end
  end

  # == The customers controller
  #
  # Controller for viewing a list of existing customers or creating a new
  # one.
  #
  # path:: /customers
  # view:: Views#customers and Views#customer_form
  class Customers
    # Gets the list of customers and displays them via Views#customers.
    def get
      @customers = Customer.all
      render :customers
    end

    # Creates a new customer object (Models::Customer) if the input is
    # valid and redirects to CustomersN.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the initial form (Views#customer_form).
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
        @target = [Customer]
        @button = "create"
        return render :customer_form
      end
      redirect R(CustomersN, @customer.id)
    end
  end

  # == The customer creation controller
  #
  # Controller for filling in the information to create a new customer.
  #
  # path:: /customers/new
  # view:: Views#customer_form
  class CustomersNew
    # Generates the form to create a new customer object (Models::Customer)
    # using Views#customer_form.
    def get
      @customer = Customer.new(:hourly_rate => HourlyRate)
      @input = @customer.attributes

      @target = [Customers]
      @button = "create"
      render :customer_form
    end
  end

  # == The customer controller
  #
  # Controller for viewing and updating information of a customer.
  #
  # path:: /customers/_customer_id_
  # view:: Views#customer_form
  class CustomersN
    # Finds the specific customer for the given _customer_id_ and shows
    # a form for updating via Views#customer_form.
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @invoices = @customer.invoices
      @input = @customer.attributes

      @target = [CustomersN, @customer.id]
      @button = "update"
      @edit_task = true
      render :customer_form
    end

    # Updates or deletes the customer with the given _customer_id_ if the
    # input is valid and redirects to CustomersN.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the initial form (Views#customer_form).
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

  # == The tasks controller for a specific customer
  #
  # Controller for creating, editing and deleting a task for a
  # specific customer.
  #
  # path:: /customers/_customer_id_/tasks
  # view:: Views#task_form
  class CustomersNTasks
    # Creates, updates or deletes a task object (Models::Task) for a
    # customer with the given _customer_id_ if the input is valid and
    # redirects to CustomersN.
    # If the provided information is invalid, the errors are retrieved and
    # shown in the initial form (Views#task_form).
    def post(customer_id)
      return redirect R(Customers) if @input.cancel
      if @input.has_key? "delete"
        @task = Task.find(@input.task_id)
        @task.delete
      elsif @input.has_key? "edit"
        return redirect R(CustomersNTasksN, customer_id, @input.task_id)
      else
        @task = Task.create(
          :customer_id => customer_id,
          :name => @input.name)
        case @input.type
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
          @customer_list = Customer.all.map do |c|
            [c.id, c.short_name.present? ? c.short_name : c.name]
          end
          @target = [CustomersNTasks, customer_id]
          @method = "create"
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end

  # == The task creation controller for a specific customer
  #
  # Controller for filling in the information to create a new task
  # for a specific customer.
  #
  # path:: /customers/_customer_id_/tasks/new
  # view:: Views#task_form
  class CustomersNTasksNew
    # Generates the form to create a new task object (Models::Task)
    # for a customer with the given _customer_id_ using Views#task_form.
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @customer_list = Customer.all.map do |c|
        [c.id, c.short_name.present? ? c.short_name : c.name]
      end
      @task = Task.new(:hourly_rate => @customer.hourly_rate)
      @input = @task.attributes
      @input["type"] = @task.type # FIXME: find nicer way!
      @input["customer"] = customer_id

      @target = [CustomersNTasks, customer_id]
      @method = "create"
      render :task_form
    end
  end

  # == The task controller for a specific customer
  #
  # Controller for viewing and updating information of a task for
  # a specific customer.
  #
  # path:: /customers/_customer_id_/tasks/_task_id_
  # view:: Views#task_form
  class CustomersNTasksN
    # Finds the task with the given _task_id_ for the customer with the
    # given _customer_id_ and shows a form for updating via
    # Views#task_form.
    def get(customer_id, task_id)
      @customer = Customer.find(customer_id)
      @customer_list = Customer.all.map do |c|
        [c.id, c.short_name.present? ? c.short_name : c.name]
      end
      @task = Task.find(task_id)
      @target = [CustomersNTasksN,  customer_id, task_id]
      @method = "update"
      @input = @task.attributes
      @input["type"] = @task.type
      @input["customer"] = customer_id
      # FIXME: Check that task is of that customer.
      render :task_form
    end

    # Updates the task with the given _task_id_ for the customer with
    # the given _customer_id_ if the input is valid and redirects to
    # CustomersN.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the intial form (Views#task_form).
    def post(customer_id, task_id)
      return redirect R(CustomersN, customer_id) if @input.cancel
      @task = Task.find(task_id)
      if @input.has_key? "update"
        @task["customer"] = Customer.find(@input["customer"])
        @task["name"] = @input["name"] unless @input["name"].blank?
        case @input.type
        when "fixed_cost"
          @task.fixed_cost = @input.fixed_cost
          @task.hourly_rate = nil
        when "hourly_rate"
          @task.fixed_cost = nil
          @task.hourly_rate = @input.hourly_rate
        end
        @task.save
        if @task.invalid?
          @errors = @task.errors
          @customer = Customer.find(customer_id)
          @customer_list = Customer.all.map do |c|
            [c.id, c.short_name.present? ? c.short_name : c.name]
          end
          @target = [CustomersNTasksN,  customer_id, task_id]
          @method = "update"
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end

  # == The invoices controller for a specific customer
  #
  # Controller for creating and viewing invoices for a specific customer.
  #
  # path:: /customers/_customer_id_/invoices
  # view:: Views#invoices
  class CustomersNInvoices
    # Gets the list of invoices for the customer with the given
    # _customer_id_ and displays them using Views#invoices.
    def get(customer_id)
      # FIXME: quick hack! is this URL even used?
      @invoices = {}
      customer = Customer.find(customer_id)
      @invoices[customer.name] = customer.invoices
      render :invoices
    end

    # Creates a new invoice object (Models::Invoice) if the input is
    # valid and redirects to CustomersNInvoicesX.
    #
    # A unique number is generated for the invoice by taking the
    # year and a sequence number.
    #
    # A fixed cost task is directly tied to the invoice.
    #
    # For a task with an hourly rate, a task copy is created with the
    # selected time to bill and put in the invoice; the remaining unbilled
    # time is left in the original task.
    def post(customer_id)
      return redirect R(CustomersN, customer_id) if @input.cancel

      # Create the invoice.
      last = Invoice.last
      number = if last
                 last_year = last.number.to_s[0..3].to_i
                 if Time.now.year > last_year
                   number = ("%d%02d" % [Time.now.year, 1])
                 else
                   number = last.number.succ
                 end
               else
                 number = ("%d%02d" % [Time.now.year, 1])
               end
      invoice = Invoice.create(:number => number)
      invoice.customer = Customer.find(customer_id)

      # Handle the hourly rated tasks first.
      tasks = Hash.new { |h, k| h[k] = Array.new }
      @input["time_entries"].each do |entry|
        time_entry = TimeEntry.find(entry)
        tasks[time_entry.task] << time_entry
      end unless @input["time_entries"].blank?
      tasks.each_key do |task|
        bill_task = task.clone # FIXME: depends on rails version!
        task.time_entries = task.time_entries - tasks[task]
        task.save
        bill_task.time_entries = tasks[task]
        bill_task.save
        invoice.tasks << bill_task
      end

      # Then, handle the fixed cost tasks.
      @input["tasks"].each do |task|
        invoice.tasks << Task.find(task)
      end unless @input["tasks"].blank?
      invoice.save

      redirect R(CustomersNInvoicesX, customer_id, number)
    end
  end

  # == The invoice controller for a specific customer
  #
  # Controller for viewing and updating information of an invoice for a
  # specific customer.
  #
  # path:: /customers/_customer_id_/invoices/_invoice_number_
  # view:: Views#invoice
  class CustomersNInvoicesX < R '/customers/(\d+)/invoices/([^/]+)'
    include ActionView::Helpers::NumberHelper
    include I18n

    # Finds the invoice with the given _invoice_number_ for the customer
    # with the given _customer_id_ and shows a form for updating via
    # Views#invoice.
    # If the invoice_number has a .pdf or .tex suffix, a PDF or LaTeX
    # source document is generated for the invoice (if not already
    # existing) and served via a redirect to the Static controller.
    def get(customer_id, invoice_number)
      # FIXME: make this (much) nicer!
      if m = invoice_number.match(/(\d+)\.(\w+)$/)
        @number = m[1].to_i
        @format = m[2]
      else
        @number = invoice_number.to_i
        @format = "html"
      end
      @invoice = Invoice.find_by_number(@number)

      @company = CompanyInfo.first
      @customer = Customer.find(customer_id)
      @tasks = @invoice.summary
      @period = @invoice.period

      if @format == "html"
        @input = @invoice.attributes
        render :invoice
      elsif @format == "tex"
        tex_file = PUBLIC_DIR + "#{@number}.tex"
        _generate_invoice_tex(@number) unless tex_file.exist?
        redirect(Static, tex_file.basename)
      elsif @format == "pdf"
        pdf_file = PUBLIC_DIR + "#{@number}.pdf"
        _generate_invoice_pdf(@number) unless pdf_file.exist?
        redirect(Static, pdf_file.basename)
      end
    end

    # Updates the invoice with the given _invoice_number_ for the customer
    # with the given _customer_id_ and redirects to CustomersNInvoicesX.
    def post(customer_id, invoice_number)
      invoice = Invoice.find_by_number(invoice_number)
      invoice.paid = @input.has_key? "paid"
      invoice.save

      redirect R(CustomersNInvoicesX, customer_id, invoice_number)
    end

    private

    # Generates a LaTex document for the invoice with the given _number_.
    def _generate_invoice_tex(number)
      template = TEMPLATE_DIR + "invoice.tex.erb"
      tex_file = PUBLIC_DIR + "#{number}.tex"

      I18n.with_locale :nl do
        erb = ERB.new(File.read(template))
        File.open(tex_file, "w") { |f| f.write(erb.result(binding)) }
      end
    end

    # Generates a PDF document for the invoice with the given _number_
    # via _generate_invoice_tex.
    def _generate_invoice_pdf(number)
      tex_file = PUBLIC_DIR + "#{@number}.tex"
      _generate_invoice_tex(number) unless tex_file.exist?

      # FIXME: remove rubber depend, use pdflatex directly
      system("rubber --pdf --inplace #{tex_file}")
      system("rubber --clean --inplace #{tex_file}")
    end
  end

  # == The invoice creating controller for a specifc customer
  #
  # Controller for creating a new invoice for a specific customer.
  #
  # path:: /customers/_customer_id_/invoices/new
  # view:: Views#invoice_select_form
  class CustomersNInvoicesNew
    # Generates the form to create a new invoice object (Models::Invoice)
    # by listing unbilled fixed cost tasks and unbilled registered time
    # (for tasks with an hourly rate) so that it can be individually selected
    # using Views#invoice_select_form.
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @hourly_rate_tasks = {}
      @fixed_cost_tasks = {}
      @customer.unbilled_tasks.each do |task|
        case task.type
        when "fixed_cost"
          total = task.time_entries.inject(0.0) { |s, te| s + te.hours_total }
          @fixed_cost_tasks[task] = total
        when "hourly_rate"
          time_entries = task.billable_time_entries
          @hourly_rate_tasks[task] = time_entries
        end
      end
      render :invoice_select_form
    end
  end

  # == The timeline controller
  #
  # Controller for presenting a timeline of registered time and
  # also for quickly registering time.
  #
  # path:: /timeline
  # view:: Views#time_entries
  class Timeline
    # Retrieves all registered time in descending order to present
    # the timeline using Views#time_entries
    def get
      @time_entries = TimeEntry.all(:order => "start DESC")
      @customer_list = Customer.all.map do |c|
        [c.id, c.short_name.present? ? c.short_name : c.name]
      end
      @task_list = Task.all.reject { |t| t.billed? }.map do |t|
        [t.id, t.name]
      end
      @input["bill"] = true # Bill by default.
      render :time_entries
    end

    # Registers a time entry and redirects to Timeline.
    # If the provided information was invalid, the errors are retrieved.
    def post
      if @input.has_key? "enter"
        @time_entry = TimeEntry.create(
          :task_id => @input.task,
          :date => @input.date,
          :start => "#{@input.date} #{@input.start}",
          :end => "#{@input.date} #{@input.end}",
          :comment => @input.comment,
          :bill => @input.has_key?("bill"))
        @time_entry.save
        if @time_entry.invalid?
          @errors = @time_entry.errors
        end
      end
      redirect R(Timeline)
    end
  end

  # == The timeline quick register controller
  #
  # Controller that presents a view for quickly registering time
  # on a task.
  #
  # path:: /timeline/new
  # view:: Views#time_entry_form
  class TimelineNew
    # Retrieves a list of customers and tasks and the current date
    # and time for prefilling a form (Views#time_entry_form) for quickly
    # registering time.
    def get
      @customer_list = Customer.all.map do |c|
        [c.id, c.short_name.present? ? c.short_name : c.name]
      end
      @task_list = Task.all.reject { |t| t.billed? }.map do |t|
        [t.id, t.name]
      end
      @input["bill"] = true
      @input["date"] = DateTime.now.to_date
      @input["start"] = Time.now.to_formatted_s(:time_only)

      @target = [Timeline]
      @button = "enter"
      render :time_entry_form
    end
  end

  # == The timeline time entry controller
  #
  # Controller for viewing and updating information of a time entry.
  #
  # path:: /timeline/_entry_id_
  # view:: Views#time_entry_form
  class TimelineN
    # Finds the time entry with the given _entry_id_ and shows
    # a form for updating via Views#time_entry_form.
    def get(entry_id)
      @time_entry = TimeEntry.find(entry_id)
      @input = @time_entry.attributes
      @input["customer"] = @time_entry.task.customer.id
      @input["task"] = @time_entry.task.id
      @input["date"] = @time_entry.date.to_date
      @input["start"] = @time_entry.start.to_formatted_s(:time_only)
      @input["end"] = @time_entry.end.to_formatted_s(:time_only)
      @customer_list = Customer.all.map do |c|
        [c.id, c.short_name.present? ? c.short_name : c.name]
      end
      @task_list = Task.all.reject { |t| t.billed? }.map do |t|
        [t.id, t.name]
      end

      @target = [TimelineN, entry_id]
      @button = "update"
      render :time_entry_form
    end

    # Updates or deletes the time entry if the input is valid and redirects
    # to Timeline.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the initial form (Views#time_entry_form).
    def post(entry_id)
      return redirect R(Timeline) if @input.cancel
      @time_entry = TimeEntry.find(entry_id)
      if @input.has_key? "delete"
        @time_entry.delete
      elsif @input.has_key? "update"
        attrs = ["date", "comment"]
        attrs.each do |attr|
          @time_entry[attr] = @input[attr]
        end
        @time_entry.start = "#{@input["date"]} #{@input["start"]}"
        @time_entry.end = "#{@input["date"]} #{@input["end"]}"
        @time_entry.task = Task.find(@input.task)
        @time_entry.bill = @input.has_key? "bill"
        @time_entry.save
        if @time_entry.invalid?
          @errors = @time_entry.errors
          return render :time_entry_form
        end
      end
      redirect R(Timeline)
    end
  end

  # == The invoices controller
  #
  # Controller for viewing a list of all invoices.
  #
  # path:: /invoices
  # view:: Views#invoices
  class Invoices
    # Retrieves the list of invoices, sorted per customer, and displays
    # them using Views#invoices.
    def get
      @invoices = {}
      Customer.all.each do |customer|
        @invoices[customer.name] = customer.invoices
      end
      render :invoices
    end
  end

  # == The invoices per period controller
  #
  # Controller for viewing a list of all invoices sorted by period.
  #
  # path:: /invoices/period
  # view:: Views#invoices
  class InvoicesPeriod
    # Retrieves the list of invoices, sorted per period, and displays
    # them using Views#invoices.
    def get
      @invoices = Hash.new { |h, k| h[k] = Array.new }
      Invoice.all.each do |invoice|
        # FIXME: this is an unformatted key!
        @invoices[invoice.period.first.at_beginning_of_month] << invoice
      end
      render :invoices
    end
  end

  # == The company controller
  #
  # Controller for viewing and updating information of the company of
  # the user (stored in Models::CompanyInfo).
  #
  # path:: /company
  # view:: Views#company_form
  class Company
    # Retrieves the company information and shows a form for updating
    # via Views#company_form.
    def get
      @company = CompanyInfo.first
      @input = @company.attributes
      render :company_form
    end

    # Updates the company information and shows the updated form
    # (Views#company_form).
    # If the provided information was invalid, the errors are retrieved.
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

  # == The static data controller
  #
  # Controller for serving static data information available in the
  # +public/+ subdirectory.
  #
  # path:: /static/_path_
  # view:: N/A (X-Sendfile)
  class Static < R '/static/(.*?)'
    # Sets the headers such that the web server will fetch and offer
    # the file identified by the _path_ relative to the +public/+ subdirectory.
    def get(path)
      unless path.include? ".."
        full_path = PUBLIC_DIR + path
        @headers['Content-Type'] = Rack::Mime.mime_type(full_path.extname)
        @headers['X-Sendfile'] = full_path.to_s
      else
        @status = "403"
        "Error 403: Invalid path: #{path}"
      end
    end
  end

end # module StopTime::Controllers

# = The Stop… Camping Time! views
module StopTime::Views

  # The main layout used by all views.
  def layout
    xhtml_strict do
      head do
        title "Stop… Camping Time!"
        # FIXME: improve static serving so that the hack below is not needed.
        link :rel => "stylesheet", :type => "text/css",
             :media => "screen",
             :href => (R(Static, "") + "stylesheets/style.css")
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

  # Partial view that generates the menu.
  def _menu
    ol.menu! do
      [["Overview", Index],
       ["Timeline", Timeline],
       ["Customers", Customers],
       ["Invoices", Invoices],
       ["Company", Company]].each { |label, ctrl| _menu_link(label, ctrl) }
    end
  end

  # Partial view that generates the menu link and determines the active
  # menu item.
  def _menu_link(label, ctrl)
    # FIXME: dirty hack?
    if self.helpers.class.to_s.match(/^#{ctrl.to_s}/)
      li.selected { a label, :href => R(ctrl) }
    else
      li { a label, :href => R(ctrl) }
    end
  end

  # The main overview showing accumulated time per task per customer.
  def overview
    h2 "Overview"

    if @tasks.empty?
      p do
        "No customers, projects or tasks found! Set them up " +
        "#{a "here", :href => R(CustomersNew)}."
      end
    else
      @tasks.keys.sort_by { |c| c.name }.each do |customer|
        h3 { a customer.name, :href => R(CustomersN, customer.id) }
        if @tasks[customer].empty?
          p do
            text "No projects/tasks found! Create one " +
                 "#{a "here", :href => R(CustomersNTasksNew, customer.id)}."
          end
        else
          table.overview do
            @tasks[customer].each do |task|
              col.task {}
              col.hours {}
              col.amount {}
              tr do
                td do
                  a task.name,
                    :href => R(CustomersNTasksN, customer.id, task.id)
                end
                summary = task.summary
                case task.type
                when "fixed_rate"
                  td ""
                  td.right { "€ %.2f" % summary[2] }
                when "hourly_rate"
                  td.right { "%.2fh" % summary[0] }
                  td.right { "€ %.2f" % summary[2] }
                end
              end
            end
          end
        end
      end
    end
  end

  # The main overview showing the timeline of registered time.
  def time_entries
    h2 "Timeline"
    table.timeline do
      col.task {}
      col.date {}
      col.start_time {}
      col.end_time {}
      col.comment {}
      col.hours {}
      col.flag {}
      tr do
        th "Project/Task"
        th "Date"
        th "Start time"
        th "End time"
        th "Comment"
        th "Total time"
        th "Bill?"
        th {}
      end
      form :action => R(Timeline), :method => :post do
        tr do
          td { _form_select("task", @task_list) }
          td { input :type => :text, :name => "date",
                     :value => DateTime.now.to_date.to_formatted_s }
          td { input :type => :text, :name => "start",
                     :value => DateTime.now.to_time.to_formatted_s(:time_only) }
          td { input :type => :text, :name => "end" }
          td { input :type => :text, :name => "comment" }
          td { "N/A" }
          td { _form_input_checkbox("bill") }
          td do
            input :type => :submit, :name => "enter", :value => "Enter"
            input :type => :reset,  :name => "clear", :value => "Clear"
          end
        end
      end
      @time_entries.each do |entry|
        tr(:class => entry.task.billed? ? "billed" : nil) do
          td { a entry.task.name,
                 :href => R(CustomersNTasksN, entry.customer.id, entry.task.id) }
          td { a entry.date.to_date,
                 :href => R(TimelineN, entry.id) }
          td { entry.start.to_formatted_s(:time_only) }
          td { entry.end.to_formatted_s(:time_only)}
          td { entry.comment }
          td { "%.2fh" % entry.hours_total }
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
            form :action => R(TimelineN, entry.id), :method => :post do
              input :type => :submit, :name => "delete", :value => "Delete"
            end
          end
        end
      end
    end
  end

  # Form for editing a time entry (Models::TimeEntry).
  def time_entry_form
    form :action => R(*target), :method => :post do
      ol do
        li do
          label "Customer", :for => "customer"
          _form_select("customer", @customer_list)
        end
        li do
          label "Task", :for => "task"
          _form_select("task", @task_list)
        end
        li { _form_input_with_label("Date", "date", :text) }
        li { _form_input_with_label("Start Time", "start", :text) }
        li { _form_input_with_label("End Time", "end", :text) }
        li { _form_input_with_label("Comment", "comment", :text) }
        li do
          _form_input_checkbox("bill")
          label "Bill?", :for => "bill"
        end
        # FIXME: link to invoice if any
      end
      input :type => "submit", :name => @button, :value => @button.capitalize
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
  end

  # The main overview of the list of customers.
  def customers
    h2 "Customers"
    if @customers.empty?
      p do
        text "None found! You can create one " +
             "#{a "here", :href => R(CustomersNew)}."
      end
    else
      table.customers do
         col.name {}
         col.short_name {}
         col.address {}
         col.email {}
         col.phone {}
         tr do
           th "Name"
           th "Short name"
           th "Address"
           th "Email"
           th "Phone"
           th {}
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

      a "Add a new customer", :href=> R(CustomersNew)
    end
  end

  # Form for editing the properties of customer (Models::Customer) but also
  # for adding/editing/deleting tasks and showing a list of invoices for
  # the customer.
  def customer_form
    form.float_left :action => R(*@target), :method => :post do
      h2 "Customer Information"
      ol do
        li { _form_input_with_label("Name", "name", :text) }
        li { _form_input_with_label("Short name", "short_name", :text) }
        li { _form_input_with_label("Street address", "address_street", :text) }
        li { _form_input_with_label("Postal code", "address_postal_code", :text) }
        li { _form_input_with_label("City/town", "address_city", :text) }
        li { _form_input_with_label("Email address", "email", :text) }
        li { _form_input_with_label("Phone number", "phone", :text) }
        li { _form_input_with_label("Default hourly rate", "hourly_rate", :text) }
      end
      input :type => "submit", :name => @button, :value => @button.capitalize
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
    if @edit_task
      # FXIME: the following is not very RESTful!
      form :action => R(CustomersNTasks, @customer.id), :method => :post do
        h2 "Projects & Tasks"
        select :name => "task_id", :size => 10 do
          @customer.tasks.each do |task|
            if task.billed?
              option(:value => task.id,
                     :disabled => true) { task.name + " (#{task.invoice.number})" }
            else
              option(:value => task.id) { task.name }
            end
          end
        end
        div do
          input :type => :submit, :name => "edit", :value => "Edit"
          input :type => :submit, :name => "delete", :value => "Delete"
          a "Add a new project/task", :href => R(CustomersNTasksNew, @customer.id)
        end
      end

      div.clear do
        h2 "Invoices"
        _invoice_list(@invoices)
        a "Create a new invoice", :href => R(CustomersNInvoicesNew, @customer.id)
      end
    end
    div.clear {}
  end

  # Partial view that generates a list of _invoices_.
  def _invoice_list(invoices)
    if invoices.empty?
      p "None found!"
    else
      table.invoices do
        col.number {}
        col.date {}
        col.period {}
        col.flag {}
        tr do
          th "Number"
          th "Date"
          th "Period"
          th "Paid?"
        end
        invoices.each do |invoice|
          tr do
            td do
              a invoice.number,
                :href => R(CustomersNInvoicesX,
                           invoice.customer.id, invoice.number)
            end
            td { invoice.created_at.to_formatted_s(:date_only) }
            td { _format_period(invoice.period) }
            # FIXME: really retrieve the paid flag.
            td { _form_input_checkbox("paid_#{invoice.number}") }
          end
        end
      end
    end
  end

  # Partial view for formatting the _period_ of an invoice.
  def _format_period(period)
    period = period.map { |m| m.to_formatted_s(:month_and_year) }.uniq
    case period.length
    when 1: period.first
    when 2: period.join("–")
    end
  end

  # Form for updating the properties of a task (Models::Task).
  def task_form
    h2 "Task Information"
    form :action => R(*@target), :method => :post do
      ol do
        li do
          label "Customer", :for => "customer"
          _form_select("customer", @customer_list)
        end
        li { _form_input_with_label("Name", "name", :text) }
        li do
          label "Project/Task type"
          ol.radio do
            li do
              _form_input_radio("type", "hourly_rate", default=true)
              _form_input_with_label("Hourly rate", "hourly_rate", :text)
            end
            li do
              _form_input_radio("type", "fixed_cost")
              _form_input_with_label("Fixed cost", "fixed_cost", :text)
            end
          end
        end
        # FIXME: add link(s) to related invoice(s)
      end
      input :type => "submit", :name => @method, :value => @method.capitalize
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
  end

  # The main overview of the existing invoices.
  def invoices
    h2 "Invoices"

    if @invoices.values.flatten.empty?
      p do
        text "Found none! You can create one by "
        a "selecting a customer", :href => R(Customers)
        text "."
      end
    else
      @invoices.keys.sort.each do |key|
        next if @invoices[key].empty?
        h3 { key }
        _invoice_list(@invoices[key])
      end
    end
  end

  # A view displaying the information (billed tasks and time) of an
  # invoice (Models::Invoice) that also allows for updating the "+paid+"
  # property.
  def invoice
    h2 do
      span "Invoice for "
      a @customer.name, :href => R(CustomersN, @customer.id)
    end

    form :action => R(CustomersNInvoicesX, @customer.id, @invoice.number),
         :method => :post do
      table do
        tr do
          td.key { b "Number" }
          td.val { @invoice.number }
        end
        tr do
          td.key { b "Date" }
          td.val { @invoice.created_at.to_formatted_s(:date_only) }
        end
        tr do
          td.key { b "Period" }
          td.val { _format_period(@invoice.period) }
        end
        tr do
          td.key { b "Paid?" }
          td.val do
            _form_input_checkbox("paid")
            input :type => :submit, :name => "update", :value => "Update"
            input :type => :reset, :name => "reset", :value => "Reset"
          end
        end
      end
    end

    table.tasks do
      col.task {}
      col.hours {}
      col.hourly_rate {}
      col.amount {}
      tr do
        th { "Project/Task" }
        th.right { "Registered time" }
        th.right { "Hourly rate" }
        th.right { "Amount" }
      end
      subtotal = 0.0
      @tasks.each do |task, line|
        tr do
          td { task }
          if line[0].nil? and line[1].nil?
            td.right "–"
            td.right "–"
          else
            td.right { "%.2fh" % line[0] }
            td.right { "€ %.2f" % line[1] }
          end
          td.right { "€ %.2f" % line[2] }
        end
        subtotal += line[2]
      end
      if @company.vatno.blank?
        vat = 0
      else
        tr do
          td { i "Sub-total" }
          td ""
          td ""
          td.right { "€ %.2f" % subtotal }
        end
        vat = subtotal * VATRate/100.0
        tr do
          td { i "VAT %d%%" % VATRate }
          td ""
          td ""
          td.right { "€ %.2f" % vat }
        end
      end
      tr.total do
        td { b "Total amount" }
        td ""
        td ""
        td.right { "€ %.2f" % (subtotal + vat) }
      end
    end

    a "Download PDF",
      :href => R(CustomersNInvoicesX, @customer.id, "#{@invoice.number}.pdf")
    a "Download Latex source",
      :href => R(CustomersNInvoicesX, @customer.id, "#{@invoice.number}.tex")
  end

  # Form for selecting fixed cost tasks and registered time for tasks with
  # an hourly rate that need to be billed.
  def invoice_select_form
    form :action => R(CustomersNInvoices, @customer.id), :method => :post do
      unless @hourly_rate_tasks.empty?
        h2 "Registered Time"
        table.invoice_select do
          col.flag {}
          col.date {}
          col.start_time {}
          col.end_time {}
          col.comment {}
          col.hours {}
          col.amount {}
          tr do
            th "Bill?"
            th "Date"
            th "Start time"
            th "End time"
            th "Comment"
            th.right "Total time"
            th.right "Amount"
          end
          @hourly_rate_tasks.keys.each do |task|
            tr.task do
              td { _form_input_checkbox("tasks[]", task.id) }
              td task.name, :colspan => 6
            end
            @hourly_rate_tasks[task].each do |entry|
              tr do
                td { _form_input_checkbox("time_entries[]", entry.id) }
                td { label entry.date.to_date,
                           :for => "time_entries[]_#{entry.id}" }
                td { entry.start.to_formatted_s(:time_only) }
                td { entry.end.to_formatted_s(:time_only) }
                td { entry.comment }
                td.right { "%.2fh" % entry.hours_total }
                td.right { "€ %.2f" % (entry.hours_total * entry.task.hourly_rate) }
              end
            end
          end
        end
      end

      unless @fixed_cost_tasks.empty?
        h2 "Fixed Cost Projects/Tasks"
        table.tasks do
          col.flag {}
          col.task {}
          col.hours {}
          col.amount {}
          tr do
            th ""
            th "Project/Task"
            th "Registered time"
            th "Amount"
          end
          @fixed_cost_tasks.keys.each do |task|
            tr do
              td { _form_input_checkbox("tasks[]", task.id) }
              td { label task.name, :for => "tasks[]_#{task.id}" }
              td.right { "%.2fh" % @fixed_cost_tasks[task] }
              td.right { task.fixed_cost }
            end
          end
        end
      end

      input :type => :submit, :name => "create", :value => "Create invoice"
      input :type => :submit, :name => "cancel", :value => "Cancel"
    end
  end

  # Form for editing the company information stored in Models::CompanyInfo.
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
      input :type => :reset, :name => "reset", :value => "Reset"
    end
  end

  # Partial view that generates a form label with the given _label_name_
  # and a form input with the given _input_name_ and _type_, such that the
  # label is linked to the input.
  def _form_input_with_label(label_name, input_name, type)
    label label_name, :for => input_name
    input :type => type, :name => input_name, :id => input_name,
          :value => @input[input_name]
  end

  # Partial view that generates a form radio button with the given _name_
  # and _value_.
  # Whether it is initially selected is determined by the _default_ flag.
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

  # Partial view that generates a form checkbox with the given _name_.
  # Whether it is initiall checked is determined by the _value_ flag.
  def _form_input_checkbox(name, value=true)
    if @input[name] == value
      input :type => "checkbox", :id => "#{name}_#{value}", :name => name,
            :value => value, :checked => true
    else
      input :type => "checkbox", :id => "#{name}_#{value}", :name => name,
            :value => value
    end
  end

  # Partial view that generates a select element for a form with a field
  # (and ID) _name_ and list of _opts_list_.
  #
  # The option list is an Array of a 2-valued array containg a value label
  # and a human readable description for the value.
  def _form_select(name, opts_list)
    if opts_list.blank?
      select :name => name, :id => name, :disabled => true do
        option "None found", :value => "none", :selected => true
      end
    else
      select :name => name, :id => name do
        opts_list.sort_by { |o| o.last }.each do |opt_val, opt_str|
          if @input[name] == opt_val
            option opt_str, :value => opt_val, :selected => true
          else
            option opt_str, :value => opt_val
          end
        end
      end
    end
  end

end # module StopTime::Views
