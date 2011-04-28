#!/usr/bin/env ruby

require_relative 'name_server'

port = 32000
puts "Running Name Server on port #{port}"

name_server = SFTP::NameServer.new(port).run
