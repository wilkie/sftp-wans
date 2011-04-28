require_relative 'client'
require 'yaml'

module SFTP
  class CLI
    EXIT_COMMANDS = ["quit", "exit", "bye"]
    
    class << self
      def run config_file = nil
        config = nil
        if config_file
          config = YAML::load_file(config_file)
        end
        @client = SFTP::Client.new config

        command = ""
        until EXIT_COMMANDS.include? command.downcase
          print "> "
          command = $stdin.readline.strip
          interpret_command command unless command.empty?
        end
      end

      def interpret_command command
        command_str = nil
        command_args = []
        command.gsub /(.+?)(\s+|$)/ do |match|
          if command_str.nil?
            command_str = match.strip.downcase
          else
            command_args << match.strip
          end
        end

        # call the associated command_* method
        function = :"command_#{command_str}"
        if @client.respond_to? function
          puts @client.send(:"command_#{command_str}", *command_args)
        else
          unless EXIT_COMMANDS.include? command_str.downcase 
            puts "Command #{command_str} not known"
          end
        end
      end
    end
  end
end
