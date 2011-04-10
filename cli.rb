require_relative 'client'

module SFTP
  class CLI
    
    class << self
      def run
        @client = SFTP::Client.new

        command = ""
        until command.downcase == "quit"
          print "> "
          command = readline.strip
          interpret_command command
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
          unless command_str.downcase == "quit"
            puts "Command #{command_str} not known"
          end
        end
      end
    end
  end
end
