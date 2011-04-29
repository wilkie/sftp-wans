#!/usr/bin/env ruby

require_relative 'server'
require 'yaml'


config = nil
if ARGV[0]
  config = YAML::load_file(ARGV[0])
end

port = 8081
data_port = 8088
server = SFTP::Server.new(config, port, data_port)

puts "Running SFTP server on port #{server.port}"

server = server.run
