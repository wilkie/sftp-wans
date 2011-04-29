#!/usr/bin/env ruby

require_relative 'name_server'

port = 8090
name_server = SFTP::NameServer.new(port)

puts "Running Name Server on port #{name_server.port}"

name_server = name_server.run
