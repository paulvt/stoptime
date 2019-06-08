#!/usr/bin/env rackup

require "bundler/setup"
require "./stoptime"

StopTime::Models::Base.establish_connection(adapter: "sqlite3",
                                            database: "db/stoptime.db",
                                            timeout: 10000)
StopTime.create
run StopTime
