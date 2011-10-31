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

  def overview
    p "There should be an overview here!"
  end
  
end # module StopTime::Views
