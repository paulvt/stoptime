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
    :date_only => "%Y-%m-%d",
    :day_code => "%Y%m%d")
  ActiveSupport::CoreExtensions::Date::Conversions::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d",
    :month_and_year => "%B %Y")

  # FIXME: this should be configurable.
  HourlyRate = 20.0
  VATRate = 0.0
end

module StopTime

  def self.create
    StopTime::Models.create_schema
  end

end

module StopTime::Models

  class Customer < Base
    has_many :tasks
    has_many :invoices
    has_many :time_entries, :through => :tasks

    def unbilled_tasks
      tasks.all(:conditions => ["invoice_id IS NULL"])
    end
  end

  class Task < Base
    has_many :time_entries
    belongs_to :customer
    belongs_to :invoice

    def fixed_cost?
      not self.fixed_cost.blank?
    end

    def type
      fixed_cost? ? "fixed_cost" : "hourly_rate"
    end

    def billable_time_entries
      time_entries.all(:conditions => ["bill = 't'"], :order => "start ASC")
    end

    def bill_period
      bte = billable_time_entries
      if bte.empty?
        # FIXME: better defaults?
        [updated_at, updated_at]
      else
        [bte.first.start, bte.last.end]
      end
    end

    def billed?
      not invoice.nil?
    end

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

  class TimeEntry < Base
    belongs_to :task
    has_one :customer, :through => :task

    def hours_total
      (self.end - self.start) / 1.hour
    end
  end

  class Invoice < Base
    has_many :tasks
    has_many :time_entries, :through => :tasks
    belongs_to :customer

    def summary
      summ = {}
      tasks.each { |task| summ[task.name] = task.summary }
      return summ
    end

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

  class ImprovedInvoiceSupport < V 1.7
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

end # StopTime::Models

module StopTime::Controllers

  class Index
    def get
      @tasks = {}
      Customer.all.each do |customer|
        @tasks[customer] = customer.unbilled_tasks
      end
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
      @invoices = @customer.invoices
      @input = @customer.attributes

      @target = [CustomersN, @customer.id]
      @edit_task = true
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
      @input["type"] = @task.type # FIXME: find nicer way!
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
      @input["type"] = @task.type
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
          @target = [CustomersNTasksN,  customer_id, task_id]
          @method = "update"
          @input = @task.attributes
          @input["type"] = @input.type
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end

  class CustomersNInvoices
    def get(customer_id)
      # FIXME: quick hack! is this URL even used?
      @invoices = {}
      customer = Customer.find(customer_id)
      @invoices[customer.name] = customer.invoices
      render :invoices
    end

    def post(customer_id)
      return redirect R(CustomersN, customer_id) if @input.cancel

      # Create the invoice.
      # FIXME: make the sequence number reset on a new year.
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

  class CustomersNInvoicesX
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
        redirect(StaticX, tex_file.basename)
      elsif @format == "pdf"
        pdf_file = PUBLIC_DIR + "#{@number}.pdf"
        _generate_invoice_pdf(@number) unless pdf_file.exist?
        redirect(StaticX, pdf_file.basename)
      end
    end

    def post(customer_id, invoice_number)
      invoice = Invoice.find_by_number(invoice_number)
      invoice.payed = @input.has_key? "payed"
      invoice.save

      redirect R(CustomersNInvoicesX, customer_id, invoice_number)
    end

    def _generate_invoice_tex(number)
      template = TEMPLATE_DIR + "invoice.tex.erb"
      tex_file = PUBLIC_DIR + "#{number}.tex"

      erb = ERB.new(File.read(template))
      File.open(tex_file, "w") { |f| f.write(erb.result(binding)) }
    end

    def _generate_invoice_pdf(number)
      tex_file = PUBLIC_DIR + "#{@number}.tex"
      _generate_invoice_tex(number) unless tex_file.exist?

      # FIXME: remove rubber depend, use pdflatex directly
      system("rubber --pdf --inplace #{tex_file}")
      system("rubber --clean --inplace #{tex_file}")
    end
  end

  class CustomersNInvoicesNew
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

  class Timeline
    def get
      @time_entries = TimeEntry.all(:order => "start DESC")
      @customer_list = Customer.all.map { |c| [c.id, c.short_name] }
      @task_list = Task.all(:conditions => ['invoice_id IS NULL']).map do
        |t| [t.id, t.name]
      end
      @input["bill"] = true # Bill by default.
      render :time_entries
    end

    def post
      if @input.has_key? "enter"
        @time_entry = TimeEntry.create(
          :task_id => @input.task,
          :start => @input.start,
          :end => @input.end,
          :comment => @input.comment,
          :bill => @input.has_key?("bill"))
        @time_entry.save
        if @time_entry.invalid?
          @errors = @time_entry.errors
        end
      elsif @input.has_key? "delete"
      end

      @time_entries = TimeEntry.all(:order => "start DESC")
      @customer_list = Customer.all.map { |c| [c.id, c.short_name] }
      @task_list = Task.all.map { |t| [t.id, t.name] }
      @input["bill"] = true # Bill by default.
      render :time_entries
    end
  end

  class TimelineN
    def get(entry_id)
      @time_entry = TimeEntry.find(entry_id)
      @input = @time_entry.attributes
      @input["customer"] = @time_entry.task.customer.id
      @input["task"] = @time_entry.task.id
      @customer_list = Customer.all.map { |c| [c.id, c.short_name] }
      @task_list = Task.all.map { |t| [t.id, t.name] }
      render :time_entry_form
    end

    def post(entry_id)
      return redirect R(Timeline) if @input.cancel
      @time_entry = TimeEntry.find(entry_id)
      if @input.has_key? "delete"
        @time_entry.delete
      elsif @input.has_key? "update"
        attrs = ["start", "end", "comment"]
        attrs.each do |attr|
          @time_entry[attr] = @input[attr]
        end
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

  class Invoices
    def get
      @invoices = {}
      Customer.all.each do |customer|
        @invoices[customer.name] = customer.invoices
      end
      render :invoices
    end
  end

  class InvoicesPeriod
    def get
      @invoices = Hash.new { |h, k| h[k] = Array.new }
      Invoice.all.each do |invoice|
        # FIXME: this is an unformatted key!
        @invoices[invoice.period.first.at_beginning_of_month] << invoice
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
      li { a "Timeline", :href => R(Timeline) }
      li { a "Customers", :href => R(Customers) }
      li { a "Invoices", :href => R(Invoices) }
      li { a "Company", :href => R(Company) }
    end
  end

  def overview
    h2 "Overview"

    if @tasks.empty?
      p do
        text "No customers found! Create one "
        a "here", :href => R(CustomersNew)
      end
    else
      @tasks.keys.sort_by { |c| c.name }.each do |customer|
        h3 { a customer.name, :href => R(CustomersN, customer.id) }
        if @tasks[customer].empty?
          p do
            text "No projects/tasks found! Create one "
            a "here", :href => R(CustomersNTasksNew, customer.id)
          end
        else
          table do
            @tasks[customer].each do |task|
              tr do
                td do
                  a task.name,
                    :href => R(CustomersNTasksN, customer.id, task.id)
                end
                summary = task.summary
                case task.type
                when "fixed_rate"
                  td ""
                  td { "€ %.2f" % summary[2] }
                when "hourly_rate"
                  td { "%.2fh" % summary[0] }
                  td { "€ %.2f" % summary[2] }
                end
              end
            end
          end
        end
      end
    end
  end

  def time_entries
    h2 "Timeline"
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
      form :action => R(Timeline), :method => :post do
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
      @time_entries.each do |entry|
        tr do
          td { a entry.customer.short_name,
                 :href => R(CustomersN, entry.customer.id) }
          td { a entry.task.name,
                 :href => R(CustomersNTasksN, entry.customer.id, entry.task.id) }
          td { a entry.start,
                 :href => R(TimelineN, entry.id) }
          td { entry.end }
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

  def time_entry_form
    form :action => R(TimelineN, @time_entry.id), :method => :post do
      ol do
        li do
          label "Customer", :for => "customer"
          _form_select("customer", @customer_list)
        end
        li do
          label "Task", :for => "task"
          _form_select("task", @task_list)
        end
        li { _form_input_with_label("Start Time", "start", :text) }
        li { _form_input_with_label("End Time", "end", :text) }
        li { _form_input_with_label("Comment", "comment", :text) }
        li do
          _form_input_checkbox("bill")
          label "Bill?", :for => "bill"
        end
        # FIXME: link to invoice if any
      end
      input :type => "submit", :name => "update", :value => "Update"
      input :type => "submit", :name => "cancel", :value => "Cancel"
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
            if task.billed?
              option(:value => task.id, 
                     :disabled => true) { task.name + " (#{task.invoice.number})" }
            else
              option(:value => task.id) { task.name }
            end
          end
        end
        input :type => :submit, :name => "edit", :value => "Edit"
        input :type => :submit, :name => "delete", :value => "Delete"
      end
      a "Add a new project/task", :href => R(CustomersNTasksNew, @customer.id)


      h2 "Invoices"
      _invoice_list(@invoices)
      a "Create a new invoice", :href => R(CustomersNInvoicesNew, @customer.id)
    end
  end

  def _invoice_list(invoices)
    if invoices.empty?
      p "None!"
    else
      table do
        tr do
          th "Number"
          th "Date"
          th "Period"
          th "Payed"
        end
        invoices.each do |invoice|
          tr do
            td do
              a invoice.number,
                :href => R(CustomersNInvoicesX, @customer.id, invoice.number)
            end
            td { invoice.created_at }
            td { _format_period(invoice.period) }
            # FIXME: really retrieve the payed flag.
            td { _form_input_checkbox("payed_#{invoice.number}") }
          end
        end
      end
    end
  end

  def _format_period(period)
    period = period.map { |m| m.to_formatted_s(:month_and_year) }.uniq
    case period.length
    when 1: period.first
    when 2: period.join("–")
    end
  end

  def task_form
    form :action => R(*@target), :method => :post do
      ul do
        li { _form_input_with_label("Name", "name", :text) }
        li do
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

  def invoices
    h2 "List of invoices"

    @invoices.keys.sort.each do |key|
      next if @invoices[key].empty?
      h3 { key }
      _invoice_list(@invoices[key])
    end
  end

  def invoice
    h2 do
      span "Invoice for "
      a @customer.name, :href => R(CustomersN, @customer.id)
    end

    form :action => R(CustomersNInvoicesX, @customer.id, @invoice.number),
         :method => :post do
      table do
        tr do
          td { b "Number" }
          td { @invoice.number }
        end
        tr do
          td { b "Date" }
          td { @invoice.created_at.to_formatted_s(:date_only) }
        end
        tr do
          td { b "Period" }
          td { _format_period(@invoice.period) }
        end
        tr do
          td { b "Payed" }
          td do
            _form_input_checkbox("payed")
            input :type => :submit, :name => "update", :value => "Update"
          end
        end
      end
    end

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
          td { task }
          if line[0].nil? and line[1].nil?
            td "–"
            td "–"
          else
            td { "%.2fh" % line[0] }
            td { "€ %.2f" % line[1] }
          end
          td { "€ %.2f" % line[2] }
        end
        subtotal += line[2]
      end
      if VATRate.zero?
        vat = 0
      else
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
      end
      tr do
        td { b "Total amount" }
        td ""
        td ""
        td { "€ %.2f" % (subtotal + vat) }
      end
    end

    a "Download PDF", 
      :href => R(CustomersNInvoicesX, @customer.id, "#{@invoice.number}.pdf")
    a "Download Latex source", 
      :href => R(CustomersNInvoicesX, @customer.id, "#{@invoice.number}.tex")
  end

  def invoice_select_form
    form :action => R(CustomersNInvoices, @customer.id), :method => :post do
      unless @hourly_rate_tasks.empty?
        h2 "Registered time"
        table do
          tr do
            th ""
            th "Start"
            th "End"
            th "Comment"
            th "Total"
            th "Amount"
          end
          @hourly_rate_tasks.keys.each do |task|
            tr.task do
              td { _form_input_checkbox("tasks[]", task.id) }
              td task.name, :colspan => 5
            end
            @hourly_rate_tasks[task].each do |entry|
              tr do
                td { _form_input_checkbox("time_entries[]", entry.id) }
                td { label entry.start, :for => "time_entries[]_#{entry.id}" }
                td { entry.end }
                td { entry.comment }
                td { "%.2fh" % entry.hours_total }
                td { "€ %.2f" % (entry.hours_total * entry.task.hourly_rate) }
              end
            end
          end
        end
      end

      unless @fixed_cost_tasks.empty?
        h2 "Fixed cost tasks"
        table do
          tr do
            th ""
            th "Task"
            th "Registered time"
            th "Amount"
          end
          @fixed_cost_tasks.keys.each do |task|
            tr do
              td { _form_input_checkbox("tasks[]", task.id) }
              td { label task.name, :for => "tasks[]_#{task.id}" }
              td { "%.2fh" % @fixed_cost_tasks[task] }
              td { task.fixed_cost }
            end
          end
        end
      end

      input :type => :submit, :name => "create", :value => "Create invoice"
      input :type => :submit, :name => "cancel", :value => "Cancel"
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
