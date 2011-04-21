#!/usr/bin/env ruby

require_relative 'server'

port = 8080
puts "Running SFTP server on port #{port}"
server = SFTP::Server.new(port)
server.run
