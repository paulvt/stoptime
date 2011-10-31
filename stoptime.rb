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

require "camping"
require "markaby"
require "pathname"

Markaby::Builder.set(:indent, 2)
Camping.goes :StopTime

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

  class CustomerN
    def get(customer_id)
      @customer = Customer.find(customer_id)
      render :customer_edit
    end

    def post(customer_id)
      return redirect R(Customers) if @input.cancel
      @customer = Customer.find(customer_id)
    end
  end

  class CustomerNew
    def get
      render :customer_edit
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
    h1 "List of customers"
    table do
       tr do
         th "Name"
         th "Short name"
         th "Email"
         th "Phone"
         th "Address"
       end
      @customers.each do |customer|
        tr do
          td { customer.name }
          td { customer.short_name }
          td { customer.email }
          td { customer.phone }
          td { [customer.address_street,
                customer.address_postal_code,
                customer.address_city].join(", ") }
          td { a "[edit]", :href => R(CustomerN, customer.id) }
        end
      end
    end
    p do
      a "Add a new customer", :href=> R(CustomerNew)
    end
  end
  
  def customer_edit
    if @customer
      target = [CustomerN, @customer.id]
    else
      @customer = {}
      target = [Customers]
    end
    form :action => R(*target), :method => :post do
      ol do 
        li { _labeled_input(@customer, "Name", "name", :text) }
        li { _labeled_input(@customer, "Short name", "short_name", :text) }
        li { _labeled_input(@customer, "Street address", "address_street", :text) }
        li { _labeled_input(@customer, "Postal code", "adress_postal_code", :text) }
        li { _labeled_input(@customer, "City/town", "adress_postal_city", :text) }
        li { _labeled_input(@customer, "Email address", "email", :text) }
        li { _labeled_input(@customer, "Phone number", "phone", :text) }
      end
      input :type => "submit", :name => "save", :value => "Save"
      input :type => "submit", :name => "cancel", :value => "Cancel"
    end
  end

  def _labeled_input(obj, label_name, input_name, type, options={})
    label label_name, :for => input_name
    input :type => type, :name => input_name, :id => input_name,
          :value => @input[input_name] || obj[input_name]
  end

end # module StopTime::Views
