#!usr/bin/env camping
# encoding: UTF-8
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
require "camping/mab"
require "camping/ar"
require "pathname"
require "sass/plugin/rack"

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

  # Set the default encodings.
  if RUBY_VERSION =~ /^1\.9/
    Encoding.default_external = Encoding::UTF_8
    Encoding.default_internal = Encoding::UTF_8
  end

  # Set the default date(/time) format.
  Time::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d %H:%M",
    :month_and_year => "%B %Y",
    :date_only => "%Y-%m-%d",
    :time_only => "%H:%M",
    :day_code => "%Y%m%d")
  Date::DATE_FORMATS.merge!(
    :default => "%Y-%m-%d",
    :month_and_year => "%B %Y")
end

# = The main application module
module StopTime

  # The version of the application
  VERSION = '1.14.0'
  puts "Starting Stop… Camping Time! version #{VERSION}"

  # @return [Hash{String=>Object}] The parsed configuration.
  attr_reader :config

  # Overrides controller call handler so that the configuration is available
  # for all controllers and views.
  def service(*a)
    @config = StopTime::Models::Config.instance
    @format = @request.path_info[/.([^.]+)/, 1];
    @headers["Content-Type"] = "text/html; charset=utf-8"
    super(*a)
  end

  # Trap the HUP signal and reload the configuration.
  Signal.trap("HUP") do
    $stderr.puts "I: caught signal HUP, reloading config"
    Models::Config.instance.reload
  end

  # Add support for PUT and DELETE.
  use Rack::MethodOverride

  # Enable SASS CSS generation from templates/sass.
  use Sass::Plugin::Rack

  # Create/migrate the database when needed.
  # @return [void]
  def self.create
    StopTime::Models.create_schema
  end

end # module StopTime

# = The Stop… Camping Time! Markaby extensions
module StopTime::Mab

  # List of support methods supported by the server.
  SUPPORTED = [:get, :post]

  # When a tag is completed (i.e. closed), perform some post-processing
  # on the tag's attributes.
  #
  # * Fix up URLs in attributes by applying +Camping::Helpers#/+ to them.
  # * Change action methods besides the supported methods (see {SUPPORTED})
  #   to +:post+ and add a hidden +_method+ input that still contains
  #   the original method.
  # * Replace underscores in the class attribute by dashes (needed for
  #   Bootstrap).
  #
  # @param [Mab::Mixin::Tag] tag the tag that is completed
  # @return [Mab::Mixin::Tag] the post-processed tag
  def mab_done(tag)
    attrs = tag._attributes

    # Fix up URLs (normally done by Camping::Mab::mab_done)
    [:href, :action, :src].map { |a| attrs[a] &&= self/attrs[a] }

    # Transform underscores into dashs in class names
    if attrs.has_key?(:class) and attrs[:class].present?
      attrs[:class] = attrs[:class].gsub('_', '-')
    end

    # The followin method processing is only for form tags.
    return super unless tag._name == :form

    meth = attrs[:method]
    attrs[:method] = 'post' if override = !SUPPORTED.include?(meth)
    # Inject a hidden input element with the proper method to the tag block
    # if the form method is unsupported.
    tag._block do |orig_blk|
      input :type => 'hidden', :name => '_method', :value => meth
      orig_blk.call
    end if override

    return super
  end

  include Mab::Indentation

end # module StopTime::Mab

# = The Stop… Camping Time! models
module StopTime::Models

  # == The configuration class
  #
  # This class contains the application configuration constructed by
  # default options (see {DefaultConfig}) merged with the configuration
  # found in the configuration file (see {ConfigFile}).
  class Config

    # There should only be a single configuration object (for reloading).
    include Singleton

    # The default configuation file. (FIXME: shouldn't be hardcoded!)
    ConfigFile = File.dirname(__FILE__) + "/config.yaml"

    # The default configuration. Note that the configuration of the root
    # will be merged with this configuration.
    DefaultConfig = { "invoice_id"       => "%Y%N",
                      "invoice_template" => "invoice",
                      "hourly_rate"      => 20.0,
                      "time_resolution"  => 1,
                      "vat_rate"         => 21.0 }

    # Creates a new configuration object and loads the configuation.
    # by reading the file +config.yaml+ on disk (see {ConfigFile}, parsing
    # it, and performing a merge with the default config (see
    # {DefaultConfig}).
    def initialize
      @config = DefaultConfig.dup
      cfg = nil
      # Read and parse the configuration.
      begin
        File.open(ConfigFile, "r") { |file| cfg = YAML.load(file) }
      rescue => e
        $stderr.puts "E: couldn't read configuration file: #{e}"
      end
      # Merge the loaded config with the default config (if it's a Hash)
      case cfg
      when Hash
        @config.merge! cfg if cfg
      when nil, false
        # It's ok, it is empty.
      else
        $stderr.puts "W: wrong format detected in configuration file!"
      end
    end

    # Reloads the configuration file.
    def reload
      load
    end

    # Returns the value for the given configuration option.
    #
    # @param [String] option a configuration option
    # @return [Object] the value for the given configuration option
    def [](option)
      @config[option]
    end

  end # class StopTime::Models::Config

  # == The customer class
  #
  # This class represents a customer that has projects/tasks
  # for which invoices need to be generated.
  class Customer < Base
    # @!attribute id [r]
    #   @return [Fixnum] unique identification number
    # @!attribute name
    #   @return [String] official (long) name
    # @!attribute short_name
    #   @return [String] abbreviated name
    # @!attribute financial_contact
    #   @return [String] name of the financial contact person/department
    # @!attribute address_street
    #   @return [String] street part of the address
    # @!attribute address_postal_code
    #   @return [String] zip/postal code part of the address
    # @!attribute address_city
    #   @return [String] city part of the postal code
    # @!attribute email
    #   @return [String] email address
    # @!attribute phone
    #   @return [String] phone number
    # @!attribute hourly_rate
    #   @return [Float] default hourly rate
    # @!attribute time_specification
    #   @return [Boolean] flag whether the customer requires time specifications
    # @!attribute created_at
    #   @return [Time] time of creation
    # @!attribute updated_at
    #   @return [Time] time of last update

    # @!attribute invoices
    #  @return [Array<Invoice>] associated invoices
    has_many :tasks
    # @!attribute tasks
    #  @return [Array<Task>] associated tasks
    has_many :invoices
    # @!attribute time_entries
    #  @return [Array<TimeEntry>] associated time entries
    has_many :time_entries, :through => :tasks

    # Returns the short name if set, otherwise the full name.
    #
    # @return [String] the shortest name
    def shortest_name
      short_name.present? ? short_name : name
    end

    # Returns a list of tasks that have not been billed via in invoice.
    #
    # @return [Array<Task>] associated unbilled tasks
    def unbilled_tasks
      tasks.where("invoice_id IS NULL").order("name ASC")
    end

    # Returns a list of tasks that are active, i.e. that have not been
    # billed and are either fixed cost or have some registered time.
    #
    # @return [Array<Task>] associated active tasks
    def active_tasks
      unbilled_tasks.select do |task|
        task.fixed_cost? or task.time_entries.present?
      end
    end
  end # class StopTime::Models::Customer

  # == The task class
  #
  # This class represents a task (or project) of a customer on which time can
  # be registered.
  # There are two types of classes:  with an hourly and with a fixed cost.
  class Task < Base
    # @!attribute id [r]
    #  @return [Fixnum] unique identification number
    # @!attribute name
    #  @return [String] description
    # @!attribute fixed_cost
    #  @return [Float] fixed cost of the task
    # @!attribute hourly_rate
    #  @return [Float] hourly rate for the task
    # @!attribute vat_rate
    #  @return [Float] VAT rate at time of billing
    # @!attribute invoice_comment
    #  @return [String] extra comment for the invoice
    # @!attribute created_at
    #  @return [Time] time of creation
    # @!attribute updated_at
    #  @return [Time] time of last update

    # @!attribute customer
    #   @return [Customer] associated customer
    belongs_to :customer
    # @!attribute time_entries
    #  @return [Array<TimeEntry>] associated registered time entries
    has_many :time_entries
    # @!attribute invoice
    #  @return [Invoice, nil] associated invoice if the task is billed,
    #    +nil+ otherwise
    belongs_to :invoice

    # Determines whether the task has a fixed cost.
    # When +false+ is returned, one can assume the task has an hourly rate.
    #
    # @return [Boolean] whether the task has a fixed cost
    def fixed_cost?
      not self.fixed_cost.blank?
    end

    # Returns the type of the task
    #
    # @return ["fixed_cose", "hourly_rate"] the type of the task
    def type
      fixed_cost? ? "fixed_cost" : "hourly_rate"
    end

    # Returns a list of time entries that should be (and are not yet)
    # billed.
    #
    # @return [Array<TimeEntry>] associated billable time entries
    def billable_time_entries
      time_entries.where("bill = 't'").order("start ASC")
    end

    # Returns the bill period of the task by means of an Array containing
    # the first and last Time object found for registered time on this
    # task.
    # If no time is registered, the last time the task has been updated
    # is returned.
    #
    # @return [Array(Time, Time)] the bill period of the task
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
    #
    # @return [Boolean] whether the task is billed
    def billed?
      not invoice.nil?
    end

    # Returns a time and cost summary of the registered time on the task
    # by means of Array of four values.
    # In case of a fixed cost task, the first value is the total of time
    # (in hours), the third value is the fixed cost, and the fourth value
    # is the VAT.
    # In case of a task with an hourly rate, the first value is
    # the total of time (in hours), the second value is the hourly rate,
    # the third value is the total amount (time times rate), and the fourth
    # value is the VAT.
    #
    # @return [Array(Float, Float, Float, Float)] the summary of the task
    def summary
      case type
      when "fixed_cost"
        total = time_entries.inject(0.0) { |summ, te| summ + te.hours_total }
        [total, nil, fixed_cost, fixed_cost * (vat_rate/100.0)]
      when "hourly_rate"
        time_entries.inject([0.0, hourly_rate, 0.0, 0.0]) do |summ, te|
          total_cost = te.hours_total * hourly_rate
          summ[0] += te.hours_total
          summ[2] += total_cost
          summ[3] += total_cost * (vat_rate/100.0)
          summ
        end
      end
    end

    # Returns an invoice comment if the task is billed and if it is
    # set, otherwise the name.
    #
    # @return [String] the invoice comment or task name (if not billed)
    def comment_or_name
      if billed? and self.invoice_comment.present?
        self.invoice_comment
      else
        self.name
      end
    end
  end # class StopTime::Models::Task

  # == The time entry class
  #
  # This class represents an amount of time that is registered on a certain
  # task.
  class TimeEntry < Base
    # @!attribute id [r]
    #   @return [Fixnum] unique identification number
    # @!attribute date
    #   @return [Time] date of the entry
    # @!attribute start
    #   @return [Time] start time of the entry
    # @!attribute end
    #   @return [Time] finish time of the entry
    # @!attribute bill
    #   @return [Boolean] flag whether to bill or not
    # @!attribute comment
    #   @return [String] additional comment
    # @!attribute created_at
    #   @return [Time] time of creation
    # @!attribute updated_at
    #   @return [Time] time of last update

    # @!attribute task
    #   @return [Task] associated task the time is registered for
    belongs_to :task
    # @!attribute customer
    #   @return [Customer] associated customer
    has_one :customer, :through => :task

    before_validation :round_start_end

    # Returns the total amount of time, the duration, in hours (up to
    # 2 decimals only!).
    #
    # @return [Float] the total amount of registered time
    def hours_total
      ((self.end - self.start) / 1.hour).round(2)
    end

    def in_current_month?
      self.end.month == Time.now.month
    end

    #########
    protected

    # Rounds the start and end time to the configured resolution using
    # {#round_time).
    #
    # @return [void]
    def round_start_end
      self.start = round_time(self.start)
      self.end = round_time(self.end)
    end

    #######
    private

    # Rounds the time using the configured time resolution.
    #
    # @param [Time] t the input time
    # @return [Time] the rounded time
    def round_time(t)
      config = Config.instance
      res = config["time_resolution"]
      down = t - (t.to_i % res.minutes)
      up = down + res.minutes

      diff_down = t - down
      diff_up = up - t

      diff_down < diff_up ? down : up
    end
  end # class StopTime::Models::TimeEntry

  # == The invoice class
  #
  # This class represents an invoice for a customer that contains billed
  # tasks and through the tasks registered time.
  class Invoice < Base
    # @!attribute id [r]
    #   @return [Fixnum] unique identification number
    # @!attribute number
    #   @return [Fixnum] invoice number
    # @!attribute paid
    #   @return [Boolean] flag whether the invoice has been paid
    # @!attribute include_specification
    #   @return [Boolean] flag whether the invoice should include a time
    #     specification
    # @!attribute created_at
    #   @return [Time] time of creation
    # @!attribute updated_at
    #   @return [Time] time of last update

    # @!attribute company_info
    #   @return [CompanyInfo] associated company info
    belongs_to :company_info
    # @!attribute customer
    #   @return [Customer] associated customer
    belongs_to :customer
    # @!attribute tasks
    #   @return [Array<Task>] associated billed tasks
    has_many :tasks
    # @!attribute time_entries
    #   @return [Array<TimeEntry>] associated billed time entries
    has_many :time_entries, :through => :tasks

    default_scope lambda { order('number DESC') }

    # Returns a time and cost summary for each of the associated tasks.
    # See also {Task#summary} for the specification of the array.
    #
    # @return [Hash{Task=>Array(Float, Float, Float, Float)}] mapping from
    #    task to summary
    def summary
      summ = {}
      tasks.each { |task| summ[task] = task.summary }
      return summ
    end

    # Returns a total per VAT rate for the summary of the associated tasks.
    # See also {#summary}.
    #
    # @return [Hash{Float=>Float}] mapping from VAT rate to total for that
    #   rate with respect to the summary
    def vat_summary
      vatsumm = Hash.new(0.0)
      summary.each do |task, summ|
        vatsumm[task.vat_rate] += summ[3]
      end
      return vatsumm
    end

    # Returns the invoice period based on the associated tasks.  This
    # period is a tuple of the earliest of the starting times and the
    # latest of the ending times of all associated tasks.
    # If there are no tasks, the creation time is used.
    #
    # See also {Task#bill_period}.
    #
    # @return [Array(Time, Time)] the invoice period
    def period
      return [created_at, created_at] if tasks.empty?

      p = [DateTime.now, DateTime.new(0)]
      tasks.each do |task|
        tp = task.bill_period
        p[0] = tp[0] if tp[0] < p[0]
        p[1] = tp[1] if tp[1] > p[1]
      end
      return p
    end

    # Returns the total amount (including VAT).
    #
    # @note VAT will only be applied if the VAT number is given in the
    #   associated company information!
    #
    # @return [Float] the total amount (including VAT)
    def total_amount
      subtotal, vattotal = summary.inject([0.0, 0.0]) do |tot, (task, summ)|
        tot[0] += summ[2]
        tot[1] += summ[3]
        tot
      end

      if company_info.vatno.blank?
        subtotal
      else
        subtotal + vattotal
      end
    end

    # Returns if the invoice is past due (i.e. it has not been paid within
    # the required amount of days).
    #
    # @return [Boolean] whether payment of the invoice is past due
    def past_due?
      not paid? and (Time.now - created_at) > 30.days # FIXME: hardcoded!
    end

    # Returns if the invoice is _way_ past due (i.e. it has not been paid
    # within twice the required amount of days).
    #
    # @return [Boolean] whether payment of the invoice is way past due
    def way_past_due?
      past_due? and (Time.now - created_at) > 2 * 30.days
    end
  end # class StopTime::Models::Invoice

  # == The company information class
  #
  # This class contains information about the company or sole
  # proprietorship of the user of Stop… Camping Time!
  class CompanyInfo < Base
    # @!attribute id [r]
    #   @return [Fixnum] unique identification number
    # @!attribute name
    #   @return [String] official company name
    # @!attribute contact_name
    #   @return [String] optional personal contact name
    # @!attribute address_street
    #   @return [String] street part of the address
    # @!attribute address_postal_code
    #   @return [String] zip/postal code part of the address
    # @!attribute address_city
    #   @return [String] city part of the postal code
    # @!attribute country
    #   @return [String] country of residence
    # @!attribute country_code
    #   @return [String] two letter country code
    # @!attribute email
    #   @return [String] email address
    # @!attribute phone
    #   @return [String] phone number
    # @!attribute cell
    #   @return [String] cellular phone number
    # @!attribute website
    #   @return [String] web address
    # @!attribute chamber
    #   @return [String] optional chamber of commerce ID number
    # @!attribute vatno
    #   @return [String] optional VAT number
    # @!attribute bank_name
    #   @return [String] name of the bank
    # @!attribute bank_bic
    #   @return [String] bank identification code (or: SWIFT code)
    # @!attribute accountname
    #   @return [String] name of the bank account holder
    # @!attribute accountno
    #   @return [String] number of the bank account
    # @!attribute accountiban
    #   @return [String] international bank account number
    # @!attribute created_at
    #   @return [Time] time of creation
    # @!attribute updated_at
    #   @return [Time] time of last update

    # @!attribute invoices
    #   @return [Array<Invoice>] associated invoices
    has_many :invoices
    # @!attribute original
    #   @return [CompanyInfo] original (previous) revision
    belongs_to :original, :class_name => "CompanyInfo"

    # Returns the revision number.
    # @return [Fixnum] the revision number
    def revision
      id
    end
  end # class StopTime::Models::CompanyInfo

  # @private
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

  # @private
  class CommentSupport < V 1.1
    def self.up
      add_column(TimeEntry.table_name, :comment, :string)
    end

    def self.down
      remove_column(TimeEntry.table_name, :comment)
    end
  end

  # @private
  class BilledFlagSupport < V 1.2
    def self.up
      add_column(TimeEntry.table_name, :bill, :boolean)
    end

    def self.down
      remove_column(TimeEntry.table_name, :bill)
    end
  end

  # @private
  class HourlyRateSupport < V 1.3
    def self.up
      config = Config.instance
      add_column(Customer.table_name, :hourly_rate, :float,
                                      :null => false,
                                      :default => config["hourly_rate"])
    end

    def self.down
      remove_column(Customer.table_name, :hourly_rate)
    end
  end

  # @private
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

  # @private
  class InvoiceSupport < V 1.5
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

  # @private
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

  # @private
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

  # @private
  class TimeEntryDateSupport < V 1.8
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

  # @private
  class PaidFlagTypoFix < V 1.9
    def self.up
      rename_column(Invoice.table_name, :payed, :paid)
    end

    def self.down
      rename_column(Invoice.table_name, :paid, :payed)
    end
  end

  # @private
  class InvoiceCommentsSupport < V 1.91
    def self.up
      add_column(Task.table_name, :invoice_comment, :string)
    end

    def self.down
      remove_column(Task.table_name, :invoice_comment)
    end
  end

  # @private
  class FinancialInfoSupport < V 1.92
    def self.up
      add_column(CompanyInfo.table_name, :bank_name, :string)
      add_column(CompanyInfo.table_name, :bank_bic, :string)
      add_column(CompanyInfo.table_name, :accountiban, :string)
      add_column(Customer.table_name, :financial_contact, :string)
    end

    def self.down
      remove_column(CompanyInfo.table_name, :bank_name)
      remove_column(CompanyInfo.table_name, :bank_bic)
      remove_column(CompanyInfo.table_name, :accountiban)
      remove_column(Customer.table_name, :financial_contact)
    end
  end

  # @private
  class CompanyInfoRevisioning < V 1.93
    def self.up
      add_column(CompanyInfo.table_name, :original_id, :integer)
      add_column(Invoice.table_name, :company_info_id, :integer)
      ci = CompanyInfo.last
      Invoice.all.each do |i|
        i.company_info = ci
        i.save
      end
    end

    def self.down
      remove_column(CompanyInfo.table_name, :original_id)
      remove_column(Invoice.table_name, :company_info_id)
    end
  end

  # @private
  class VATRatePerTaskSupport < V 1.94
    def self.up
      add_column(Task.table_name, :vat_rate, :float)
      config = Config.instance
      Task.all.each do |t|
        t.vat_rate = config['vat_rate']
        t.save
      end
    end

    def self.down
      remove_column(Task.table_name, :vat_rate)
    end
  end

  # @private
  class TimeSpecificationSupport < V 1.95
    def self.up
      add_column(Customer.table_name, :time_specification, :boolean)
      add_column(Invoice.table_name, :include_specification, :boolean)

      Customer.reset_column_information
      Invoice.reset_column_information
    end

    def self.down
      remove_column(Customer.table_name, :time_specification)
      remove_column(Invoice.table_name, :include_specification)
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
  # path:: +/+
  # view:: {Views#overview}
  class Index
    # Shows an overview of all unbilled projects/tasks per customer using
    # {Views#overview}.
    def get
      @tasks = {}
      @task_count = 0
      @active_tasks = {}
      @active_tasks_summary = {}
      @totals = [0.0, 0,0]
      Customer.all.each do |customer|
        tasks = customer.unbilled_tasks
        @tasks[customer] = tasks
        @task_count += tasks.count
        active_tasks = customer.active_tasks
        @active_tasks[customer] = active_tasks
        @active_tasks_summary[customer] =
          active_tasks.inject([0.0, 0.0]) do |summ, task|
            task_summ = task.summary
            summ[0] += task_summ[0]
            @totals[0] += task_summ[0]
            summ[1] += task_summ[2]
            @totals[1] += task_summ[2]
            summ
          end
      end
      render :overview
    end
  end # class StopTime::Controllers::Index

  # == The customers controller
  #
  # Controller for viewing a list of existing customers or creating a new
  # one.
  #
  # path:: +/customers+
  # view:: {Views#customers} and {Views#customer_form}
  class Customers
    # Show the list of customers and displays them using {Views#customers}.
    def get
      @customers = Customer.order("name ASC")
      render :customers
    end

    # Creates a new customer object ({Models::Customer}) if the input is
    # valid and redirects to {CustomersN}.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the initial form ({Views#customer_form}).
    def post
      return redirect R(Customers) if @input.cancel
      @customer = Customer.create(
        :name => @input.name,
        :short_name => @input.short_name,
        :financial_contact => @input.financial_contact,
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
  end # class StopTime::Controllers::CustomersN

  # == The customer creation controller
  #
  # Controller for filling in the information to create a new customer.
  #
  # path:: +/customers/new+
  # view:: {Views#customer_form}
  class CustomersNew
    # Generates the form to create a new customer object ({Models::Customer})
    # using {Views#customer_form}.
    def get
      @customer = Customer.new(:hourly_rate => @config['hourly_rate'])
      @input = @customer.attributes
      @tasks = []

      @target = [Customers]
      @button = "create"
      render :customer_form
    end
  end

  # == The customer controller
  #
  # Controller for viewing and updating information of a customer.
  #
  # path:: +/customers/+_customer_id_
  # view:: {Views#customer_form}
  class CustomersN
    # Finds the specific customer for the given customer ID and shows
    # a form for updating using {Views#customer_form}.
    #
    # @param [Fixnum] customer_id ID of the customer
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @input = @customer.attributes
      @tasks = @customer.tasks.order("name ASC, invoice_id ASC")
      # FIXME: this dirty hack assumes that tasks have unique names,
      # becasue there is no reference from billed tasks to its original
      # task.
      @billed_tasks = {}
      cur_active_task = nil
      @tasks.each do |task|
        if task.billed?
          if cur_active_task.nil? or
             task.name != cur_active_task.name
            # Apparently, this is billed but it does not belong to the
            # current active task, so probably it was a fixed-cost task
            cur_active_task = task
            @billed_tasks[task] = [task]
          else
            @billed_tasks[cur_active_task] << task
          end
        else
          cur_active_task = task
          @billed_tasks[task] = []
        end
      end

      @time_entries = @customer.time_entries.order("start DESC")
      @invoices = @customer.invoices
      @invoices.each do |i|
        @input["paid_#{i.number}"] = true if i.paid?
      end
      @task_list = Hash.new { |h, k| h[k] = Array.new }
      @customer.tasks.reject { |t| t.billed? }.each do |t|
        @task_list[t.customer.shortest_name] << [t.id, t.name]
      end
      @input["bill"] = true # Bill by default.
      @input["task"] = @time_entries.first.task.id if @time_entries.present?

      @target = [CustomersN, @customer.id]
      @button = "update"
      @edit_task = true
      render :customer_form
    end

    # Updates or deletes the customer with the given customer ID if the
    # input is valid and redirects to {CustomersN}.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the initial form ({Views#customer_form}).
    #
    # @param [Fixnum] customer_id ID of the customer
    def post(customer_id)
      return redirect R(Customers) if @input.cancel
      @customer = Customer.find(customer_id)
      if @input.has_key? "delete"
        @customer.delete
      elsif @input.has_key? "update"
        attrs = ["name", "short_name", "financial_contact",
                 "address_street", "address_postal_code", "address_city",
                 "email", "phone", "hourly_rate"]
        attrs.each do |attr|
          @customer[attr] = @input[attr]
        end
        @customer.time_specification = @input.has_key? "time_specification"
        @customer.save
        if @customer.invalid?
          @errors = @customer.errors
          return render :customer_form
        end
      end
      redirect R(Customers)
    end
  end # class StopTime::Controllers::CustomersN

  # == The tasks controller for a specific customer
  #
  # Controller for creating, editing and deleting a task for a
  # specific customer.
  #
  # path:: +/customers/+_customer_id_+/tasks+
  # view:: {Views#task_form}
  class CustomersNTasks
    # Creates, updates or deletes a task object ({Models::Task}) for a
    # customer with the given customer ID if the input is valid and
    # redirects to {CustomersN}.
    # If the provided information is invalid, the errors are retrieved and
    # shown in the initial form ({Views#task_form}).
    #
    # @param [Fixnum] customer_id ID of the customer
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
        @task.vat_rate = @input.vat_rate
        @task.save
        if @task.invalid?
          @errors = @task.errors
          @customer = Customer.find(customer_id)
          @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
          @time_entries = @task.time_entries.order("start DESC")
          @time_entries.each do |te|
            @input["bill_#{te.id}"] = true if te.bill?
          end

          @target = [CustomersNTasks, customer_id]
          @method = "create"
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end # class StopTime::Controllers::CustomersNTasks

  # == The task creation controller for a specific customer
  #
  # Controller for filling in the information to create a new task
  # for a specific customer.
  #
  # path:: +/customers/+_customer_id_+/tasks/new+
  # view:: {Views#task_form}
  class CustomersNTasksNew
    # Generates the form to create a new task object ({Models::Task})
    # for a customer with the given customer ID_ using {Views#task_form}.
    #
    # @param [Fixnum] customer_id ID of the customer
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
      @task = Task.new(:hourly_rate => @customer.hourly_rate,
                       :vat_rate => @config["vat_rate"])
      @input = @task.attributes
      @input["type"] = @task.type # FIXME: find nicer way!
      @input["customer"] = @customer.id

      @target = [CustomersNTasks, customer_id]
      @method = "create"
      render :task_form
    end
  end # class StopTime::Controllers::CustomersNTasksNew

  # == The task controller for a specific customer
  #
  # Controller for viewing and updating information of a task for
  # a specific customer.
  #
  # path:: +/customers/+_customer_id_+/tasks/+_task_id_
  # view:: {Views#task_form}
  class CustomersNTasksN
    # Finds the task with the given task ID for the customer with the given
    # customer ID and shows a form for updating using {Views#task_form}.
    #
    # @param [Fixnum] customer_id ID of the customer
    # @param [Fixnum] task_id ID of the task
    def get(customer_id, task_id)
      @customer = Customer.find(customer_id)
      @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
      @task = Task.find(task_id)
      @time_entries = @task.time_entries.order("start DESC")

      @input = @task.attributes
      @input["type"] = @task.type
      @input["customer"] = @customer.id
      @time_entries.each do |te|
        @input["bill_#{te.id}"] = true if te.bill?
      end
      @input["bill"] = true # Bill new entries by default.

      # FIXME: Check that task is of that customer.
      @target = [CustomersNTasksN,  customer_id, task_id]
      @method = "update"
      render :task_form
    end

    # Updates the task with the given task ID_ for the customer with
    # the given customer ID if the input is valid and redirects to
    # {CustomersN}.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the intial form ({Views#task_form}).
    #
    # @param [Fixnum] customer_id ID of the customer
    # @param [Fixnum] task_id ID of the task
    def post(customer_id, task_id)
      return redirect R(CustomersN, customer_id) if @input.cancel
      @task = Task.find(task_id)
      if @input.has_key? "update"
        @task.customer = Customer.find(@input["customer"])
        @task.name = @input["name"] unless @input["name"].blank?
        if @task.billed? and @input["invoice_comment"].present?
          @task.invoice_comment = @input["invoice_comment"]
        end
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
          @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
          @target = [CustomersNTasksN,  customer_id, task_id]
          @method = "update"
          return render :task_form
        end
      end
      redirect R(CustomersN, customer_id)
    end
  end # class StopTime::Controllers::CustomersNTasksN

  # == The invoices controller for a specific customer
  #
  # Controller for creating and viewing invoices for a specific customer.
  #
  # path:: +/customers/+_customer_id_+/invoices+
  # view:: {Views#invoices}
  class CustomersNInvoices
    # Gets the list of invoices for the customer with the given customer ID
    # and displays them using {Views#invoices}.
    #
    # @param [Fixnum] customer_id ID of the customer
    def get(customer_id)
      # FIXME: quick hack! is this URL even used?
      customer = Customer.find(customer_id)
      customer.invoices.each do |i|
        @input["paid_#{i.number}"] = true if i.paid?
      end
      @invoices = {customer.name => customer.invoices}

      render :invoices
    end

    # Creates a new invoice object ({Models::Invoice}) for the customer
    # with the given customer ID if the input is valid and redirects to
    # {CustomersNInvoicesX}.
    #
    # A unique number is generated for the invoice by taking the
    # year and a sequence number.
    #
    # A fixed cost task is directly tied to the invoice.
    #
    # For a task with an hourly rate, a task copy is created with the
    # selected time to bill and put in the invoice; the remaining unbilled
    # time is left in the original task.
    #
    # @param [Fixnum] customer_id ID of the customer
    def post(customer_id)
      return redirect R(CustomersN, customer_id) if @input.cancel

      # Create the invoice.
      last = Invoice.reorder('number ASC').last
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
      invoice.company_info = CompanyInfo.last
      invoice.include_specification = invoice.customer.time_specification

      # Handle the hourly rated tasks first by looking at the selected time
      # entries.
      tasks = Hash.new { |h, k| h[k] = Array.new }
      @input["time_entries"].each do |entry|
        time_entry = TimeEntry.find(entry)
        tasks[time_entry.task] << time_entry
      end unless @input["time_entries"].blank?
      tasks.each_key do |task|
        # Create a new (billed) task clone that contains the selected time
        # entries, leave the rest unbilled and associated with their task.
        bill_task = task.dup # FIXME: depends on rails version!
        task.time_entries = task.time_entries - tasks[task]
        task.save
        bill_task.time_entries = tasks[task]
        bill_task.invoice_comment = @input["task_#{task.id}_comment"]
        bill_task.save
        invoice.tasks << bill_task
      end

      # Then, handle the (selected) fixed cost tasks.
      @input["tasks"].each do |task|
        task = Task.find(task)
        next unless task.fixed_cost?
        task.invoice_comment = @input["task_#{task.id}_comment"]
        task.save
        invoice.tasks << task
      end unless @input["tasks"].blank?
      invoice.save

      redirect R(CustomersNInvoicesX, customer_id, number)
    end
  end # class StopTime::Controllers::CustomersNInvoices

  # == The invoice controller for a specific customer
  #
  # Controller for viewing and updating information of an invoice for a
  # specific customer.
  #
  # path:: +/customers/+_customer_id_+/invoices/+_invoice_number_
  # view:: {Views#invoice_form}
  class CustomersNInvoicesX < R '/customers/(\d+)/invoices/([^/]+)'
    include ActionView::Helpers::NumberHelper
    include I18n

    # Finds the invoice with the given invoice number for the customer
    # with the given customer ID and shows a form for updating using
    # {Views#invoice_form}.
    # If the invoice_number has a .pdf or .tex suffix, a PDF or LaTeX
    # source document is generated for the invoice (if not already
    # existing) and served via a redirect to the {Static} controller.
    #
    # @param [Fixnum] customer_id ID of the customer
    # @param [Fixnum] invoice_number number of the invoice
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
      @customer = Customer.find(customer_id)

      @company = @invoice.company_info
      @tasks = @invoice.summary
      @vat = @invoice.vat_summary
      @period = @invoice.period

      tex_file = PUBLIC_DIR + "invoices/#{@number}.tex"
      pdf_file = PUBLIC_DIR + "invoices/#{@number}.pdf"
      if @format == "html"
        @input = @invoice.attributes
        @invoice_file_present = tex_file.exist?
        render :invoice_form
      elsif @format == "tex"
        _generate_invoice_tex(@number) unless tex_file.exist?
        redirect R(Static, "") + "invoices/#{tex_file.basename}"
      elsif @format == "pdf"
        _generate_invoice_pdf(@number) unless pdf_file.exist?
        redirect R(Static, "") + "invoices/#{pdf_file.basename}"
      end
    end

    # Updates the invoice with the given invoice number for the customer
    # with the given customer ID and redirects to {CustomersNInvoicesX}.
    #
    # @param [Fixnum] customer_id ID of the customer
    # @param [Fixnum] invoice_number number of the invoice
    def post(customer_id, invoice_number)
      invoice = Invoice.find_by_number(invoice_number)
      invoice.paid = @input.has_key? "paid"
      invoice.include_specification = @input.has_key? "include_specification"
      invoice.save

      redirect R(CustomersNInvoicesX, customer_id, invoice_number)
    end

    # Find the invoice with the given invoice number for the customer
    # with the given customer ID and deletes existing invoice files.
    #
    # @param [Fixnum] customer_id ID of the customer
    # @param [Fixnum] invoice_number number of the invoice
    def delete(customer_id, invoice_number)
      @invoice = Invoice.find_by_number(@number)
      @customer = Customer.find(customer_id)

      tex_file = PUBLIC_DIR + "invoices/#{invoice_number}.tex"
      File.unlink(tex_file) if tex_file.exist?

      pdf_file = PUBLIC_DIR + "invoices/#{invoice_number}.pdf"
      File.unlink(pdf_file) if pdf_file.exist?

      redirect R(CustomersNInvoicesX, customer_id, invoice_number)
    end

    ########################
    # Private helper methods
    #
    private

    # Escapes the given string such that it can be used as in in
    # LaTeX.
    #
    # @param [String] string the given string
    def _escape_latex(string)
     escape_chars = { '#'  => '\#',
                      '$'  => '\$',
                      '%'  => '\%',
                      '&'  => '\&',
                      '\\' => '\textbackslash{}',
                      '^'  => '\textasciicircum{}',
                      '_'  => '\_',
                      '{'  => '\{',
                      '}'  => '\}',
                      '~'  => '\textasciitilde{}' }
      regexp_str = escape_chars.keys.map { |c| Regexp.escape(c) }.join('|')
      regexp = Regexp.new(regexp_str)
      string.to_s.gsub(regexp, escape_chars)
    end
    alias_method :l, :_escape_latex

    # Generates a LaTex document for the invoice with the given number.
    #
    # @param [Fixnum] number number of the invoice
    def _generate_invoice_tex(number)
      template = TEMPLATE_DIR + "#{@config["invoice_template"]}.tex.erb"
      tex_file = PUBLIC_DIR + "invoices/#{number}.tex"

      I18n.with_locale :nl do
        erb = ERB.new(File.read(template))
        File.open(tex_file, "w") { |f| f.write(erb.result(binding)) }
      end
    rescue Exception => err
      tex_file.delete if File.exist? tex_file
      raise err
    end

    # Generates a PDF document for the invoice with the given number
    # using {#_generate_invoice_tex}.
    #
    # @param [Fixnum] number number of the invoice
    def _generate_invoice_pdf(number)
      tex_file = PUBLIC_DIR + "invoices/#{@number}.tex"
      _generate_invoice_tex(number) unless tex_file.exist?

      # FIXME: remove rubber depend, use pdflatex directly
      system("rubber --pdf --inplace #{tex_file}")
      system("rubber --clean --inplace #{tex_file}")
    end
  end # class StopTime::Controllers::CustomerNInvoicesX

  # == The invoice creating controller for a specifc customer
  #
  # Controller for creating a new invoice for a specific customer.
  #
  # path:: +/customers/+_customer_id_+/invoices/new+
  # view:: {Views#invoice_select_form}
  class CustomersNInvoicesNew
    # Generates the form to create a new invoice object ({Models::Invoice})
    # by listing unbilled fixed cost tasks and unbilled registered time
    # (for tasks with an hourly rate) of the customer with the given
    # customer ID so that it can be individually selected using
    # {Views#invoice_select_form}.
    #
    # @param [Fixnum] customer_id ID of the customer
    def get(customer_id)
      @customer = Customer.find(customer_id)
      @hourly_rate_tasks = {}
      @fixed_cost_tasks = {}
      @customer.active_tasks.each do |task|
        case task.type
        when "fixed_cost"
          total = task.time_entries.inject(0.0) { |s, te| s + te.hours_total }
          @fixed_cost_tasks[task] = total
        when "hourly_rate"
          time_entries = task.billable_time_entries
          @hourly_rate_tasks[task] = time_entries
        end
      end
      @none_found = @hourly_rate_tasks.empty? and @fixed_cost_tasks.empty?
      render :invoice_select_form
    end
  end # class StopTime::Controllers::CustomersNInvoicesNew

  # == The timeline controller
  #
  # Controller for presenting a timeline of registered time and
  # also for quickly registering time.
  #
  # path:: +/timeline+
  # view:: {Views#timeline}
  class Timeline
    # Retrieves all registered time in descending order to present
    # the timeline using {Views#timeline}.
    def get
      if @input["show"] == "all"
        @time_entries = TimeEntry.order("start DESC")
      else
        @time_entries = TimeEntry.joins(:task)\
                                 .where("stoptime_tasks.invoice_id" => nil)\
                                 .order("start DESC")
      end
      @time_entries.each do |te|
        @input["bill_#{te.id}"] = true if te.bill?
      end
      @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
      @task_list = Hash.new { |h, k| h[k] = Array.new }
      Task.all.reject { |t| t.billed? }.each do |t|
        @task_list[t.customer.shortest_name] << [t.id, t.name]
      end
      @input["bill"] = true # Bill by default.
      @input["task"] = @time_entries.first.task.id if @time_entries.present?
      render :timeline
    end

    # Registers a time entry and redirects back to the referer.
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
        # Add a day to the end date if the total hours is negative.
        # It means that the end time was before the begin time, i.e.
        # overnight.
        @time_entry.end += 1.day if @time_entry.hours_total < 0
        @time_entry.save
        if @time_entry.invalid?
          @errors = @time_entry.errors
        end
      end
      redirect @request.referer
    end
  end # class StopTime::Controllers::Timeline

  # == The timeline quick register controller
  #
  # Controller that presents a view for quickly registering time
  # on a task.
  #
  # path:: +/timeline/new+
  # view:: {Views#time_entry_form}
  class TimelineNew
    # Retrieves a list of customers and tasks and the current date
    # and time for prefilling a form ({Views#time_entry_form}) for quickly
    # registering time.
    def get
      @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
      @task_list = Hash.new { |h, k| h[k] = Array.new }
      Task.all.reject { |t| t.billed? }.each do |t|
        @task_list[t.customer.shortest_name] << [t.id, t.name]
      end
      @input["bill"] = true
      @input["date"] = DateTime.now.to_date
      @input["start"] = Time.now.to_formatted_s(:time_only)

      @target = [Timeline]
      @button = "enter"
      render :time_entry_form
    end
  end # class StopTime::Controllers::TimelineNew

  # == The timeline time entry controller
  #
  # Controller for viewing and updating information of a time entry.
  #
  # path:: +/timeline/+_entry_id_
  # view:: {Views#time_entry_form}
  class TimelineN
    # Finds the time entry with the given time entry ID and shows
    # a form for updating using {Views#time_entry_form}.
    #
    # @param [Fixnum] entry_id ID of the time entry
    def get(entry_id)
      @time_entry = TimeEntry.find(entry_id)
      @input = @time_entry.attributes
      @input["customer"] = @time_entry.task.customer.id
      @input["task"] = @time_entry.task.id
      @input["date"] = @time_entry.date.to_date
      @input["start"] = @time_entry.start.to_formatted_s(:time_only)
      @input["end"] = @time_entry.end.to_formatted_s(:time_only)
      @customer_list = Customer.all.map { |c| [c.id, c.shortest_name] }
      @task_list = Hash.new { |h, k| h[k] = Array.new }
      Task.order("name ASC, invoice_id ASC").each do |t|
        name = t.billed? ? t.name + " (#{t.invoice.number})" : t.name
        @task_list[t.customer.shortest_name] << [t.id, name]
      end

      @target = [TimelineN, entry_id]
      @button = "update"
      render :time_entry_form
    end

    # Updates or deletes the time entry if the input is valid and redirects
    # to {Timeline}.
    # If the provided information is invalid, the errors are retrieved
    # and shown in the initial form ({Views#time_entry_form}).
    #
    # @param [Fixnum] entry_id ID of the time entry
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
        # Add a day to the end date if the total hours is negative.
        @time_entry.end += 1.day if @time_entry.hours_total < 0
        @time_entry.save
        if @time_entry.invalid?
          @errors = @time_entry.errors
          return render :time_entry_form
        end
      end
      redirect @request.referer
    end
  end # class StopTime::Controllers::TimelineN

  # == The invoices controller
  #
  # Controller for viewing a list of all invoices.
  #
  # path:: +/invoices+
  # view:: {Views#invoices}
  class Invoices
    # Retrieves the list of invoices, sorted per customer, and displays
    # them using {Views#invoices}.
    def get
      @invoices = {}
      @invoice_count = 0
      Customer.all.each do |customer|
        invoices = customer.invoices
        next if invoices.empty?
        @invoices[customer] = invoices
        invoices.each do |i|
          @input["paid_#{i.number}"] = true if i.paid?
        end
        @invoice_count += invoices.count
      end
      render :invoices
    end
  end # class StopTime::Controllers::Invoices

  # == The invoices per period controller
  #
  # Controller for viewing a list of all invoices sorted by period.
  #
  # path:: +/invoices/period+
  # view:: {Views#invoices}
  class InvoicesPeriod
    # Retrieves the list of invoices, sorted per period, and displays
    # them using {Views#invoices}.
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
  # path:: +/company+
  # view:: {Views#company_form}
  class Company
    # Retrieves the company information and shows a form for updating
    # using {Views#company_form}.
    def get
      @company = if @input.revision.present?
                   CompanyInfo.find(@input.revision)
                 else
                   CompanyInfo.last
                 end
      @input = @company.attributes
      @history_warn = true if @company != CompanyInfo.last
      render :company_form
    end

    # Updates the company information and shows the updated form
    # ({Views#company_form}).
    # If the provided information was invalid, the errors are retrieved.
    def post
      @company = if @input.revision.present?
                   CompanyInfo.find(@input.revision)
                 else
                   CompanyInfo.last
                 end
      # If we are editing the current info and it is already associated
      # with some invoices, create a new revision.
      @history_warn = true if @company != CompanyInfo.last
      if @company == CompanyInfo.last and @company.invoices.length > 0
        old_company = @company
        @company = old_company.clone # FIXME: depends on rails versioN!
        @company.original = old_company
      end

      attrs = ["name", "contact_name",
               "address_street", "address_postal_code", "address_city",
               "country", "country_code",
               "phone", "cell", "email", "website",
               "chamber", "vatno",
               "bank_name", "bank_bic", "accountno", "accountiban"]
      attrs.each do |attr|
        @company[attr] = @input[attr]
      end
      @company.save
      if @company.invalid?
        @errors = @company.errors
      end
      render :company_form
    end
  end # class StopTime::Controllers::Company

  # == The static data controller
  #
  # Controller for serving static data information available in the
  # +public/+ subdirectory.
  #
  # path:: +/static/+_path_
  # view:: N/A (X-Sendfile)
  class Static < R '/static/(.*?)'
    # Sets the headers such that the web server will fetch and offer
    # the file identified by the path relative to the +public/+ subdirectory.
    #
    # @param [String] path the relative path to a public data file
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
  end # class StopTime::Controllers::Static

end # module StopTime::Controllers

# = The Stop… Camping Time! views
module StopTime::Views

  # The main layout used by all views.
  #
  # @return [Mab::Mixin::Tag] the main layout
  def layout
    doctype!
    html(:lang => "en") do
      head do
        title "Stop… Camping Time!"
        meta :name => "viewport",
             :content => "width=device-width, initial-scale=1.0"
        # Bootstrap core CSS
        link :rel => "stylesheet", :type => "text/css",
             :media => "screen",
             :href => (R(Static, "") + "stylesheets/bootstrap.min.css")
        # FIXME: improve static serving so that the hack below is not needed.
        link :rel => "stylesheet", :type => "text/css",
             :media => "screen",
             :href => (R(Static, "") + "stylesheets/style.css")
        # Enable responsiveness
        meta :name => "viewport",
             :content => "width=device-width, initial-scale=1, " +
                         "maximum-scale=1, user-scalable=no"

      end
      body do
        _menu
        div.container do
          self << yield
          footer { br }
        end
        footer.footer do
          div.container do
            small do
              text! "Stop… Camping Time! v#{StopTime::VERSION} — by "
              a "Mozcode", :href => "https://mozcode.nl"
            end
          end
        end
        # JQuery and Bootstrap JavaScript
        script :src => (R(Static, "") + "javascripts/jquery.min.js")
        script :src => (R(Static, "") + "javascripts/bootstrap.min.js")
      end
    end
  end

  # The main overview showing accumulated time per task per customer.
  #
  # @return [Mab::Mixin::Tag] the main overview
  def overview
    header.page_header do
      h1 do
        text! "Overview"
        small "#{@tasks.count} customers, #{@task_count} active projects/tasks"
      end
    end
    if @tasks.empty?
      div.alert.alert_info do
        text! "No customers, projects or tasks found! Set them up " +
              "#{a "here", :href => R(CustomersNew)}."
      end
    else
      div.row do
        @tasks.keys.sort_by { |c| c.name }.each do |customer|
          div.span6 do
            inv_klass = "text_info"
            inv_klass = "text_warning" if customer.invoices.any? { |inv| inv.past_due? }
            inv_klass = "text_error" if customer.invoices.any? { |inv| inv.way_past_due? }
            h3 { a customer.name,
                   :class => inv_klass,
                   :href => R(CustomersN, customer.id) }
            if @tasks[customer].empty?
              p do
                text! "No projects/tasks found! Create one " +
                      "#{a "here", :href => R(CustomersNTasksNew, customer.id)}."
              end
            elsif @active_tasks[customer].empty?
              p do
                text! "No active projects/tasks found! " +
                      "Register time on one of these tasks: "
                br
                @tasks[customer].each do |task|
                   a task.name, :href => R(CustomersNTasksN, customer.id, task.id)
                   text! "&centerdot;" unless task == @tasks[customer].last
                end
              end
            else
              table.table.table_condensed do
                col.task
                col.hours
                col.amount
                @active_tasks[customer].each do |task|
                  tr do
                    summary = task.summary
                    td do
                      a task.name,
                        :href => R(CustomersNTasksN, customer.id, task.id)
                    end
                    summary = task.summary
                    td.text_right { "%.2fh" % summary[0] }
                    td.text_right { "€ %.2f" % summary[2] }
                  end
                end
                tr do
                  td { b "Total" }
                  td.text_right { "%.2fh" % @active_tasks_summary[customer][0] }
                  td.text_right { "€ %.2f" % @active_tasks_summary[customer][1] }
                end
              end
            end
          end
        end
      end
      div.row do
        div.span12 do
          table.table.table_condensed.grand_total do
            col
            col.total_hours
            col.total_amount
            tr do
              td { big { b "Grand total" } }
              td.text_right { big { b("%.2fh" % @totals[0]) } }
              td.text_right { big { b("€ %.2f" % @totals[1]) } }
            end
          end
        end
      end
    end
  end

  # The main overview showing the timeline of registered time.
  #
  # @return [Mab::Mixin::Tag] the main timeline (time entry list) overview
  def timeline
    header.page_header do
      h1 do
        text! "Timeline"
        small "#{@time_entries.count} time entries"
        div.btn_group.pull_right do
          a.btn.btn_small.dropdown_toggle :href => "#", "data-toggle" => "dropdown" do
            text! @input["show"] == "all" ? "All" : "Unbilled"
            span.caret
          end
          ul.dropdown_menu :role => "menu", :aria_labelledby => "dLabel" do
            li { a "All", :href => R(Timeline, :show => "all") }
            li { a "Unbilled", :href => R(Timeline, :show => "unbilled") }
          end
        end
      end
    end
    _time_entries
  end

  # Form for editing a time entry ({Models::TimeEntry}).
  #
  # @return [Mab::Mixin::Tag] the time entry form
  def time_entry_form
    header.page_header do
      h1 do
        text! "Time Entry Information"
        small @input["comment"]
      end
    end
    div.alert do
      button.close(:type => "button", "data-dismiss" => "alert") { "&times;" }
      strong "Warning!"
      text! "This time entry is already billed!  Only make changes if you know " +
            "what you are doing!"
    end if @time_entry.present? and @time_entry.task.billed?
    form.form_horizontal.form_condensed :action => R(*@target), :method => :post do
      div.control_group do
        label.control_label "Customer", :for => "customer"
        div.controls do
          _form_select("customer", @customer_list)
          a.btn "» Go to customer", :href => R(CustomersN, @time_entry.customer.id)
        end
      end
      div.control_group do
        label.control_label "Project/Task", :for => "task"
        div.controls do
          _form_select_nested("task", @task_list)
          a.btn "» Go to project/task", :href => R(CustomersNTasksN,
                                                   @time_entry.customer.id,
                                                   @time_entry.task.id)
        end
      end
      if @time_entry.present? and @time_entry.task.billed?
        div.control_group do
          label.control_label "Billed in invoice"
          div.controls do
            a @time_entry.task.invoice.number,
              :href => R(CustomersNInvoicesX, @time_entry.customer.id,
                                              @time_entry.task.invoice.number)
          end
        end
      end
      _form_input_with_label("Date", "date", :text, :class => "input-small")
      _form_input_with_label("Start Time", "start", :text, :class => "input-mini")
      _form_input_with_label("End Time", "end", :text, :class => "input-mini")
      _form_input_with_label("Comment", "comment", :text, :class => "input-xxlarge")
      div.control_group do
        label.control_label "Bill?", :for => "bill"
        div.controls do
          _form_input_checkbox("bill")
        end
      end
      # FIXME: link to invoice if any
      div.form_actions do
        button.btn.btn_primary @button.capitalize, :type => "submit",
          :name => @button, :value => @button.capitalize
        button.btn "Cancel", :type => "submit",
          :name => "cancel", :value => "Cancel"
      end
    end
  end

  # The main overview of the list of customers.
  #
  # @return [Mab::Mixin::Tag] the customer list overview
  def customers
    header.page_header do
      h1 do
        text! "Customers"
        div.btn_group.pull_right do
          a.btn.btn_small "» Add a new customer", :href=> R(CustomersNew)
        end
      end
    end
    if @customers.empty?
      div.alert.alert_info do
        text! "None found! You can create one " +
              "#{a "here", :href => R(CustomersNew)}."
      end
    else
      table.table.table_striped.table_condensed do
        col.name
        col.short_name
        col.address
        col.email
        col.phone
        thead do
          tr do
            th "Name"
            th "Short name"
            th "Address"
            th "Email"
            th "Phone"
            th {}
          end
        end
        tbody do
          @customers.each do |customer|
            tr do
              td { a customer.name, :href => R(CustomersN, customer.id) }
              td { customer.short_name  || "–"}
              td do
                if customer.address_street.present?
                  text! customer.address_street
                  br
                  text! customer.address_postal_code + "&nbsp;" +
                        customer.address_city
                else
                  "–"
                end
              end
              td do
                if customer.email.present?
                  a customer.email, :href => "mailto:#{customer.email}"
                else
                  "–"
                end
              end
              td do
                if customer.phone.present?
                  # FIXME: hardcoded prefix!
                  "0#{customer.phone}"
                else
                  "–"
                end
              end
              td do
                form :action => R(CustomersN, customer.id), :method => :post do
                  button.btn.btn_mini.btn_danger "Delete", :type => :submit,
                    :name => "delete", :value => "Delete"
                end
              end
            end
          end
        end
      end
    end
  end

  # Form for editing the properties of customer ({Models::Customer}) but also
  # for adding/editing/deleting tasks and showing a list of invoices for
  # the customer.
  #
  # @return [Mab::Mixin::Tag] the customer form
  def customer_form
    header.page_header do
      h1 do
        text! "Customer Information"
        small @input["name"]
      end
    end
    div.row do
      div.span6 do
        h2 "Details"
        form.form_horizontal.form_condensed :action => R(*@target), :method => :post do
          _form_input_with_label("Name", "name", :text)
          _form_input_with_label("Short name", "short_name", :text)
          _form_input_with_label("Street address", "address_street", :text)
          _form_input_with_label("Postal code", "address_postal_code", :text)
          _form_input_with_label("City/town", "address_city", :text)
          _form_input_with_label("Email address", "email", :email)
          _form_input_with_label("Phone number", "phone", :tel)
          _form_input_with_label("Financial contact", "financial_contact", :text)
          _form_input_with_label("Default hourly rate", "hourly_rate", :text)
          div.control_group do
            label.control_label "Time specifications?"
            div.controls do
              _form_input_checkbox("time_specification")
            end
          end
          div.form_actions do
            button.btn.btn_primary @button.capitalize, :type => "submit",
              :name => @button, :value => @button.capitalize
            button.btn "Cancel", :type => "submit",
              :name => "cancel", :value => "Cancel"
          end
        end
      end

      div.span6 do
        if @edit_task
          h2 do
            text! "Projects & Tasks"
            div.btn_group.pull_right do
              a.btn.btn_small "» Add a new project/task",
                              :href => R(CustomersNTasksNew, @customer.id)
            end
          end
          if @billed_tasks.empty?
            p "None found!"
          else
            div.accordion.task_list! do
              @billed_tasks.keys.sort_by { |task| task.name }.each do |task|
                div.accordion_group do
                  div.accordion_heading do
                    span.accordion_toggle do
                      a task.name, "data-toggle" => "collapse",
                                   "data-parent" => "#task_list",
                                   :href => "#collapse#{task.id}"
                      # FXIME: the following is not very RESTful!
                      form.form_inline.pull_right :action => R(CustomersNTasks, @customer.id),
                                       :method => :post do
                        a.btn.btn_mini "Edit", :href => R(CustomersNTasksN, @customer.id, task.id)
                        input :type => :hidden, :name => "task_id", :value => task.id
                        button.btn.btn_danger.btn_mini "Delete", :type => :submit,
                          :name => "delete", :value => "Delete"
                      end
                    end
                  end
                  div.accordion_body.collapse :id => "collapse#{task.id}" do
                    div.accordion_inner do
                      if @billed_tasks[task].empty?
                        i { "No billed projects/tasks found" }
                      else
                        table.table.table_condensed do
                          col.task_list
                          @billed_tasks[task].sort_by { |t| t.invoice.number }.each do |billed_task|
                            tr do
                              td do
                                a billed_task.comment_or_name,
                                  :href => R(CustomersNTasksN, @customer.id, billed_task.id)
                                small do
                                  text! "(billed in invoice "
                                  a billed_task.invoice.number,
                                    :title => billed_task.invoice.number,
                                    :href => R(CustomersNInvoicesX, @customer.id,
                                                                    billed_task.invoice.number)
                                  text! ")"
                                end
                              end
                              td do
                                # FXIME: the following is not very RESTful!
                                form.form_inline.pull_right :action => R(CustomersNTasks, @customer.id),
                                                 :method => :post do
                                  a.btn.btn_mini "Edit",
                                                 :href => R(CustomersNTasksN, @customer.id,
                                                                              billed_task.id)
                                  input :type => :hidden, :name => "task_id",
                                        :value => billed_task.id
                                  button.btn.btn_danger.btn_mini "Delete", :type => :submit,
                                    :name => "delete", :value => "Delete"
                                end
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end

          h2 do
            text! "Invoices"
            div.btn_group.pull_right do
              a.btn.btn_small "» Create a new invoice",
                              :href => R(CustomersNInvoicesNew, @customer.id)
            end
          end
          _invoice_list(@invoices)
        end
      end
    end

    div.row do
      div.span12 do
        # Show registered time (ab)using the time_entries view as partial view.
        h2 "Registered time"
        _time_entries(@customer) unless @method == "create"
      end
    end
  end

  # Form for updating the properties of a task ({Models::Task}).
  #
  # @return [Mab::Mixin::Tag] the task form
  def task_form
    header.page_header do
      h1 do
        text! "Task Information"
        small @task.name
      end
    end
    div.alert do
      button.close(:type => "button", "data-dismiss" => "alert") { "&times;" }
      strong "Warning!"
      text! "This task is already billed!  Only make changes if you know " +
            "what you are doing!"
    end if @task.billed?
    form.form_horizontal.form_condensed :action => R(*@target), :method => :post do
      div.control_group do
        label.control_label "Customer", :for => "customer"
        div.controls do
          _form_select("customer", @customer_list)
          a.btn "» Go to customer", :href => R(CustomersN, @customer.id)
        end
      end
      _form_input_with_label("Name", "name", :text)
      div.control_group do
        label.control_label "Project/Task type"
        div.controls do
          label.radio do
            _form_input_radio("type", "hourly_rate", true)
            text!("Hourly rate: ")
            _form_input("hourly_rate", :number, "Hourly rate", :class => "input-small")
          end
          label.radio do
            _form_input_radio("type", "fixed_cost")
            text!("Fixed cost: ")
            _form_input("fixed_cost", :number, "Fixed cost", :class => "input-small")
          end
        end
      end
      _form_input_with_label("VAT rate", "vat_rate", :number, :class => "input-small")
      if @task.billed?
        div.control_group do
          label.control_label "Billed in invoice"
          div.controls do
            a @task.invoice.number,
              :href => R(CustomersNInvoicesX, @customer.id, @task.invoice.number)
          end
        end
        _form_input_with_label("Invoice comment", "invoice_comment", :text)
      end
      div.form_actions do
        button.btn.btn_primary @method.capitalize, :type => "submit",
          :name => @method, :value => @method.capitalize
        button.btn "Cancel", :type => "submit",
          :name => "cancel", :value => "Cancel"
      end
    end
    # Show registered time (ab)using the time_entries view as partial view.
    h2 "Registered #{@task.billed? ? "billed" : "unbilled"} time"
    _time_entries(@customer, @task) unless @method == "create"
  end

  # The main overview of the existing invoices.
  #
  # @return [Mab::Mixin::Tag] the invoices list overview
  def invoices
    header.page_header do
      h1 do
        text! "Invoices"
        small "#{@invoices.count} customers, #{@invoice_count} invoices"
      end
    end
    if @invoices.values.flatten.empty?
      div.alert.alert_info do
        text! "Found none! You can create one by " +
              "#{a "selecting a customer", :href => R(Customers)}."
      end
    else
      div.row do
        div.span7 do
          @invoices.keys.sort.each do |customer|
            next if @invoices[customer].empty?
            h2 do
              text! customer.name
              div.btn_group.pull_right do
                a.btn.btn_small "» Create a new invoice",
                                :href => R(CustomersNInvoicesNew, customer.id)
              end
            end
            _invoice_list(@invoices[customer])
          end
        end
      end
    end
  end

  # A view displaying the information (billed tasks and time) of an
  # invoice ({Models::Invoice}) that also allows for updating the "+paid+"
  # property.
  #
  # @return [Mab::Mixin::Tag] the invoice form
  def invoice_form
    header.page_header do
      h1 do
        text! "Invoice for "
        a @customer.name, :href => R(CustomersN, @customer.id)
      end
    end
    div.row do
      div.span6 do
        form.form_horizontal.form_condensed :action => R(CustomersNInvoicesX, @customer.id, @invoice.number),
             :method => :post do
          _form_input_with_label("Number", "number", :text, :disabled => true,
            :class => "input-small")
          div.control_group do
            label.control_label "Date"
            div.controls do
              input.input_medium :type => :text, :name => "created_at",
                :id => "created_at",
                :value => @invoice.created_at.to_formatted_s(:date_only),
                :placeholder => "Date", :disabled => true
            end
          end
          div.control_group do
            label.control_label "Period"
            div.controls do
              input.input_large :type => :text, :name => "period", :id => "period",
                :value => _format_period(@invoice.period),
                :placeholder => "Period", :disabled => true
            end
          end
          div.control_group do
            label.control_label "Paid?"
            div.controls do
              _form_input_checkbox("paid")
            end
          end
          div.control_group do
            label.control_label "Include specification?"
            div.controls do
              _form_input_checkbox("include_specification")
            end
          end
          div.form_actions do
            button.btn.btn_primary "Update", :type => :submit,
              :name => "update", :value => "Update"
            button.btn "Reset", :type => :reset,
              :name => "reset", :value => "Reset"
          end
        end
      end
      div.span6 do
        table.table.table_condensed.table_striped do
          col.task
          col.reg_hours
          col.hourly_rate
          col.amount
          thead do
            tr do
              th { "Project/Task" }
              th.text_right { "Registered" }
              th.text_right { "Hourly rt." }
              th.text_right { "Amount" }
            end
          end
          tbody do
            subtotal = 0.0
            @tasks.each do |task, line|
              tr do
                td do
                  a task.comment_or_name,
                    :title => task.comment_or_name,
                    :href => R(CustomersNTasksN, task.customer.id, task.id)
                end
                if line[1].blank?
                  # FIXME: information of time spent is available in the summary
                  # but show it?
                  td.text_right { "%.2fh" % line[0] }
                  td.text_right "–"
                else
                  td.text_right { "%.2fh" % line[0] }
                  td.text_right { "€ %.2f" % line[1] }
                end
                td.text_right { "€ %.2f" % line[2] }
              end
              subtotal += line[2]
              task.time_entries.each do |entry|
                tr do
                  td.indent do
                    time_spec = "from #{entry.start.to_formatted_s(:time_only)} " +
                                "until #{entry.end.to_formatted_s(:time_only)} " +
                                "on #{entry.date.to_date}"
                    if entry.comment.present?
                      a "• #{entry.comment}", :href => R(TimelineN, entry.id),
                                              :title => "#{entry.comment} (#{time_spec})"
                    else
                      a(:href => R(TimelineN, entry.id),
                        :title => time_spec) { i "• None" }
                    end
                  end
                  td.text_right { "%.2fh" % entry.hours_total }
                  td.text_right { "–" }
                  td.text_right { "–" }
                end
              end unless task.fixed_cost?
            end
            vattotal = 0.0
            if @company.vatno.present?
              tr.total do
                td { i "Sub-total" }
                td ""
                td ""
                td.text_right { "€ %.2f" % subtotal }
              end
              @vat.keys.sort.each do |rate|
                vattotal += @vat[rate]
                tr do
                  td { i "VAT %d%%" % rate }
                  td ""
                  td ""
                  td.text_right { "€ %.2f" % @vat[rate] }
                end
              end
            end
            tr.total do
              td { b "Total" }
              td ""
              td ""
              td.text_right { "€ %.2f" % (subtotal + vattotal) }
            end
          end
        end

        div.btn_group do
          a.btn.btn_primary "» Download PDF",
            :href => R(CustomersNInvoicesX, @customer.id, "#{@invoice.number}.pdf")
          a.btn "» Download LaTeX source",
            :href => R(CustomersNInvoicesX, @customer.id, "#{@invoice.number}.tex")
          a.btn "» View company info",
            :href => R(Company, :revision => @company.revision)
        end

        div.alert.alert_danger do
          form.form_inline :action => R(CustomersNInvoicesX,
                                        @customer.id, @invoice.number),
                           :method => :delete do
            button.btn.btn_danger "» Remove old", :type => "submit"
            text! "An invoice has already been generated!"
          end
        end if @invoice_file_present
      end
    end
  end

  # Form for selecting fixed cost tasks and registered time for tasks with
  # an hourly rate that need to be billed.
  #
  # @return [Mab::Mixin::Tag] the invoice construction form
  def invoice_select_form
    header.page_header do
      h1 do
        text! "Create Invoice for "
        a @customer.name, :href => R(CustomersN, @customer.id)
      end
    end
    div.row do
      div.span10 do
        if @none_found
          div.alert.alert_info do
            "No fixed costs tasks or tasks with an hourly rate found!"
          end
        end
        form.form_horizontal :action => R(CustomersNInvoices, @customer.id),
                             :method => :post do
          unless @hourly_rate_tasks.empty?
            h3 "Projects/Tasks with an Hourly Rate"
            table.table.table_striped.table_condensed do
              col.flag
              col.date
              col.start_time
              col.end_time
              col.comment
              col.hours
              col.amount
              thead do
                tr do
                  th "Bill?"
                  th "Date"
                  th "Start"
                  th "End"
                  th "Comment"
                  th.text_right "Total"
                  th.text_right "Amount"
                end
              end
              tbody do
                @hourly_rate_tasks.keys.each do |task|
                  tr.task do
                    td { _form_input_checkbox("tasks[]", task.id, true) }
                    td task.name, :colspan => 3
                    td do
                      input :type =>  :text, :name => "task_#{task.id}_comment",
                            :id => "tasks_#{task.id}_comment", :value => task.name
                    td {}
                    td {}
                    end
                  end
                  @hourly_rate_tasks[task].each do |entry|
                    tr do
                      td.indent { _form_input_checkbox("time_entries[]", entry.id, !entry.in_current_month?) }
                      td { label entry.date.to_date,
                                 :for => "time_entries[]_#{entry.id}" }
                      td { entry.start.to_formatted_s(:time_only) }
                      td { entry.end.to_formatted_s(:time_only) }
                      td { entry.comment }
                      td.text_right { "%.2fh" % entry.hours_total }
                      td.text_right { "€ %.2f" % (entry.hours_total * entry.task.hourly_rate) }
                    end
                  end
                end
              end
            end
          end

          unless @fixed_cost_tasks.empty?
            h3 "Fixed Cost Projects/Tasks"
            table.table.table_striped.table_condensed do
              col.flag
              col.task
              col.comment
              col.hours
              col.amount
              thead do
                tr do
                  th "Bill?"
                  th "Project/Task"
                  th "Comment"
                  th.text_right "Registered time"
                  th.text_right "Amount"
                end
              end
              tbody do
                @fixed_cost_tasks.keys.each do |task|
                  tr do
                    td { _form_input_checkbox("tasks[]", task.id, true) }
                    td { label task.name, :for => "tasks[]_#{task.id}" }
                    td do
                      input :type =>  :text, :name => "task_#{task.id}_comment",
                            :id => "tasks_#{task.id}_comment", :value => task.name
                    end
                    td.text_right { "%.2fh" % @fixed_cost_tasks[task] }
                    td.text_right { task.fixed_cost }
                  end
                end
              end
            end
          end

          div.form_actions do
            button.btn.btn_primary "Create invoice", :type => :submit,
              :name => "create", :value => "Create invoice",
              :disabled => @none_found
            button.btn "Cancel", :type => :submit,
              :name => "cancel", :value => "Cancel"
          end
        end
      end
    end
  end

  # Form for editing the company information ({Models::CompanyInfo}).
  #
  # @return [Mab::Mixin::Tag] the company information form
  def company_form
    header.page_header do
      h1 do
        text! "Company Information"
        small @company.name
      end
    end
    div.alert.alert_error.alert_block do
      button.close(:type => "button", "data-dismiss" => "alert") { "&times;" }
      h4 "There were #{@errors.count} errors in the form!"
      ul do
        @errors.each do |attrib, msg|
          li "#{attrib.to_s.capitalize} #{msg}"
        end
      end
    end if @errors
    div.alert.alert_info do
      text! " Viewing revision #{@company.revision}, " +
            " last update at #{@company.updated_at}."
      if @company.original.present?
        a.btn "» View previous revision",
          :href => R(Company, :revision => @company.original.revision)
      end
    end
    div.alert.alert_block do
      button.close(:type => "button", "data-dismiss" => "alert") { "&times;" }
      h4 "Warning!"
      text! "This company information is already associated with some invoices! "
      br
      text! "Only make changes if you know what you are doing!"
    end if @history_warn
    form.form_horizontal.form_condensed :action => R(Company, :revision => @company.revision),
      :method => :post do
      _form_input_with_label("Name", "name", :text)
      _form_input_with_label("Contact name", "contact_name", :text)
      _form_input_with_label("Street address", "address_street", :text)
      _form_input_with_label("Postal code", "address_postal_code", :text)
      _form_input_with_label("City/town", "address_city", :text)
      _form_input_with_label("Phone number", "phone", :tel)
      _form_input_with_label("Cellular number", "cell", :tel)
      _form_input_with_label("Email address", "email", :email)
      _form_input_with_label("Web address", "website", :url)

      h3 "Corporate information"
      _form_input_with_label("Chamber number", "chamber", :text)
      _form_input_with_label("VAT number", "vatno", :text)

      h3 "Bank information"
      _form_input_with_label("Name", "bank_name", :text)
      _form_input_with_label("Identification code", "bank_bic", :text)
      _form_input_with_label("Account holder", "accountname", :text)
      _form_input_with_label("Account number", "accountno", :text)
      _form_input_with_label("Intl. account number", "accountiban", :text)

      div.form_actions do
        button.btn.btn_primary "Update", :type => "submit",
          :name => "update", :value => "Update"
        button.tbn "Reset", :type => :reset, :name => "reset",
          :value => "Reset"
      end
    end
  end

  ###############
  # Partial views
  #
  private

  # Partial view that generates the menu.
  #
  # @return [Mab::Mixin::Tag] the main menu
  def _menu
    nav.navbar.navbar_fixed_top do
      div.navbar_inner do
        div.container do
          a.brand(:href => R(Index)) { "Stop… Camping Time!" }
          ul.nav do
            [["Overview", Index],
             ["Timeline", Timeline],
             ["Customers", Customers],
             ["Invoices", Invoices],
             ["Company", Company]].each { |label, ctrl| _menu_link(label, ctrl) }
          end
        end
      end
    end
  end

  # Partial view that generates the menu link and determines the active
  # menu item.
  #
  # @param [String] label menu item label
  # @param [Object] ctrl menu item target controller
  # @return [Mab::Mixin::Tag] a menu item link tag
  def _menu_link(label, ctrl)
    # FIXME: dirty hack?
    if self.class.to_s.match(/^#{ctrl.to_s}/)
      li.active { a label, :href => R(ctrl) }
    else
      li { a label, :href => R(ctrl) }
    end
  end

  # Partial view that generates a list of invoices.
  #
  # @param [Array<Invoice>] invoices list of invoices
  # @return [Mab::Mixin::Tag] a list of invoices
  def _invoice_list(invoices)
    if invoices.empty?
      p "None found!"
    else
      table.table.table_striped.table_condensed do
        col.number
        col.date
        col.period
        col.amount
        col.flag
        thead do
          tr do
            th "Number"
            th "Date"
            th "Period"
            th.text_right "Amount"
            th "Paid?"
          end
        end
        tbody do
          invoices.each do |invoice|
            due_class = invoice.past_due? ? "warning" : ""
            due_class = "error" if invoice.way_past_due?
            tr(:class => due_class) do
              td do
                a invoice.number,
                  :href => R(CustomersNInvoicesX,
                             invoice.customer.id, invoice.number)
              end
              td { invoice.created_at.to_formatted_s(:date_only) }
              td { _format_period(invoice.period) }
              td.text_right { "€ %.2f" % invoice.total_amount }
              td do
                i(:class => "icon-ok") if invoice.paid?
              end
            end
          end
        end
      end
    end
  end

  # Partial view for formatting the period of an invoice.
  #
  # @param [Array(Time), Array(Time, Time)] period invoice period
  # @return [String] formatted period of an invoice
  def _format_period(period)
    period = period.map { |m| m.to_formatted_s(:month_and_year) }.uniq
    case period.length
    when 1
      period.first
    when 2
      period.join("–")
    end
  end

  # Partial view that generates a form input.
  #
  # @param [String] input_name name of the input
  # @param [String] type type of the input
  # @param [String] placeholder placeholder text
  # @param [Hash] html_options options passed on to the resulting
  #   Markaby/Mab tag
  # @return [Mab::Mixin::Tag] a form input tag
  def _form_input(input_name, type, placeholder, html_options={})
    html_options.merge!(:type => type, :name => input_name,
                        :id => input_name, :value => @input[input_name],
                        :placeholder => placeholder)
    input(html_options)
  end

  # Partial view that generates a form label and a form input, such that
  # the label is linked to the input.
  #
  # @param [String] label_name label for the input
  # @param [String] input_name name of the input
  # @param [String] type type of the input
  # @param [Hash] html_options options passed on to the resulting
  #   Markaby/Mab tag
  # @return [Mab::Mixin::Tag] a form input tag
  def _form_input_with_label(label_name, input_name, type, html_options={})
    div.control_group do
      label.control_label label_name, :for => input_name
      div.controls do
        _form_input(input_name, type, label_name, html_options)
      end
    end
  end

  # Partial view that generates a form radio button.
  #
  # @param [String] name name of the radio button
  # @param [String] value value of the radio button
  # @param [Boolean] default whether the radio button is initially selected
  # @param [Array] opts additional Markaby/Mab tag options
  # @return [Mab::Mixin::Tag] a form radio button input tag
  def _form_input_radio(name, value, default=false, *opts)
    input_val = @input[name]
    if input_val == value or (input_val.blank? and default)
      input({:type => "radio", :id => "#{name}_#{value}",
             :name => name, :value => value, :checked => true}, *opts)
    else
      input({:type => "radio", :id => "#{name}_#{value}",
             :name => name, :value => value}, *opts)
    end
  end

  # Partial view that generates a form checkbox.
  # Whether it is initially checked is determined by the _default_ flag.
  # Additional options can be passed via the collection _opts_.
  #
  # @param [String] name name of the checkbox
  # @param [Boolean] value whether the checkbox is checked
  # @param [Boolean] default whether the checkbox is initially checked
  # @param [Array] opts additional Markaby/Mab tag options
  # @return [Mab::Mixin::Tag] a form checkbox input tag
  def _form_input_checkbox(name, value=true, default=false, *opts)
    if @input[name] == value or default
      input({:type => "checkbox", :id => "#{name}_#{value}", :name => name,
             :value => value, :checked => true}, *opts)
    else
      input({:type => "checkbox", :id => "#{name}_#{value}", :name => name,
             :value => value}, *opts)
    end
  end

  # Partial view that generates a form select element.
  #
  # The option list is an Array of a 2-valued array containg a value label
  # and a human readable description for the value.
  #
  # @param [String] name name of the form select element
  # @param [Array(String, String)] opts_list list of options (value and
  #   description)
  # @param [Hash] html_options options passed on to the resulting
  #   Markaby/Mab tag
  # @return [Mab::Mixin::Tag] a form select input tag
  def _form_select(name, opts_list, html_options={})
    if opts_list.blank?
      html_options.merge!(:name => name, :id => name, :disabled => true)
      select(html_options) do
        option "None found", :value => "none", :selected => true
      end
    else
      html_options.merge!(:name => name, :id => name)
      select(html_options) do
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

  # Partial view similar to {Views#_form_select} that generates a (nested)
  # select element for a form.
  #
  # In this case, the option lists represents a subdivision of the options,
  # where the key is the name of the subdivision and the value the options
  # list as in {Views#_form_select}.
  #
  # So, the option list is an Hash of Strings mapping to Arrays of a
  # 2-valued array containg a value label and a human readable description
  # for the value.
  #
  # @param [String] name name of the form select element
  # @param [Hash{String=>Array(String, String)}] opts list of options (section
  #   name to value and description)
  # @param [Hash] html_options options passed on to the resulting
  #   Markaby/Mab tag
  # @return [Mab::Mixin::Tag] a form select input tag
  def _form_select_nested(name, opts, html_options={})
    if opts.blank?
      html_options.merge!(:name => name, :id => name, :disabled => true)
      select(html_options) do
        option "None found", :value => "none", :selected => true
      end
    else
      html_options.merge!(:name => name, :id => name)
      select(html_options) do
        opts.keys.sort.each do |key|
          optgroup :label => key do
            opts[key].sort_by { |o| o.last }.each do |opt_val, opt_str|
              if @input[name] == opt_val
                option(opt_str, {:value => opt_val, :selected => true})
              else
                option(opt_str, {:value => opt_val})
              end
            end
          end
        end
      end
    end
  end

  # Partial view that shows time entries.  If a customer is given,
  # only time entries of that customer are shown, and if also a task is
  # given, then only the time entries of that task are shown.
  #
  # @param [Customer, nil] customer an customer to show time entries for
  # @param [Customer, nil] task a task to show time entries for
  # @return [Mab::Mixin::Tag] the main menu
  def _time_entries(customer=nil, task=nil)
    table.table.table_condensed.table_striped.table_hover do
      if customer.blank?
        col.customer_short
      end
      if task.blank?
        col.task
      end
      col.date
      col.start_time
      col.end_time
      col.comment
      col.hours
      col.flag
      thead do
        tr do
          if customer.blank?
            th "Customer"
          end
          if task.blank?
            th "Project/Task"
          end
          th "Date"
          th "Start"
          th "End"
          th "Comment"
          th "Total"
          th "Bill?"
          th {}
        end
      end
      tbody do
        form.form_inline :action => R(Timeline), :method => :post do
          tr do
            if task.present?
              input :type => :hidden, :name => "task", :value => task.id
            else
              if customer.blank?
                td { }
              end
              td { _form_select_nested("task", @task_list, :class => "task") }
            end
            td { input.date :type => :text, :name => "date",
                            :value => DateTime.now.to_date.to_formatted_s }
            td { input.start_time :type => :text, :name => "start",
                                  :value => DateTime.now.to_time.to_formatted_s(:time_only) }
            td { input.end_time :type => :text, :name => "end" }
            td { input.comment :type => :text, :name => "comment" }
            td { "N/A" }
            td { _form_input_checkbox("bill") }
            td do
              button.btn.btn_small.btn_primary "Enter",
                                               :type => :submit,
                                               :name => "enter",
                                               :value => "Enter"
            end
          end
        end
        @time_entries.each do |entry|
          tr(:class => entry.task.billed? ? "billed" : nil) do
            if customer.blank?
              td do
                a entry.customer.shortest_name,
                  :title => entry.customer.shortest_name,
                  :href => R(CustomersN, entry.customer.id)
              end
            end
            if task.blank?
              td do
                a entry.task.name,
                  :title => entry.task.name,
                  :href => R(CustomersNTasksN, entry.customer.id, entry.task.id)
              end
            end
            td { entry.date.to_date }
            td { entry.start.to_formatted_s(:time_only) }
            td { entry.end.to_formatted_s(:time_only)}
            if entry.comment.present?
              td { a entry.comment, :href => R(TimelineN, entry.id),
                                    :title => entry.comment }
            else
              td { a(:href => R(TimelineN, entry.id)) { i "None" } }
            end
            td { "%.2fh" % entry.hours_total }
            td do
              i(:class => "icon-ok") if entry.bill?
            end
            td do
              form.form_inline :action => R(TimelineN, entry.id), :method => :post do
                button.btn.btn_mini.btn_danger "Delete", :type => :submit, :name => "delete", :value => "Delete"
              end
            end
          end
        end
      end
    end
  end

end # module StopTime::Views
