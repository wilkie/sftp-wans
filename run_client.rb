require_relative 'client'
require_relative 'cli'

SFTP::CLI.run ARGV[0]
