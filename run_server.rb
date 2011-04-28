#!/usr/bin/env ruby

require_relative 'server'
require 'yaml'

port = 8085
data_port = 8086
puts "Running SFTP server on port #{port}"

config = nil
if ARGV[0]
  config = YAML::load_file(ARGV[0])
end

server = SFTP::Server.new(config, port, data_port)
server.run
