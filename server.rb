require 'socket'

module SFTP
  class Server
    DEFAULT_PORT = 8080

    def initialize(port = DEFAULT_PORT)
      @clients = []
      @directories = []
      @listener = TCPServer.new('127.0.0.1', port)
    end

    def run
      while true do
        selected = select([@listener] + @clients).first
        next if selected.nil?

        selected.each do |socket|
          if socket == @listener
            # The socket is the connection listener
            puts "New client #{@clients.count}"
            client = @listener.accept
            @clients << client
            @directories << Dir.new(Dir.pwd)
          else
            # The socket is a client

            @index = @clients.index socket
            @client = socket
            @directory = @directories[@index]

            begin
              if socket.closed? || socket.eof?
                puts "Client #{@index} closed"
                @clients.delete_at @index
                @directories.delete_at @index
                socket.close
              else
                puts "Client #{@index} command"
                interpret_command socket.readline
              end
            rescue
              # Just close the socket
              puts "Client #{@index} closed"
              @clients.delete_at @index
              @directories.delete_at @index
              socket.close
            end
          end
        end
      end
    end

    def interpret_command(command)
      puts "Command: #{command}"
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
      if self.respond_to? function
        puts "Command #{command_str} #{command_args}}"
        self.send(:"command_#{command_str}", *command_args)
      else
        puts "Command #{command_str} not known"
      end
    end

    # Commands

    # SFTP
    def command_sftp
    end

    # OPEN
    def command_open
    end

    # PWD
    # Responds: working directory: /home/foo/dir
    def command_pwd
      # Respond with absolute path for this client
      puts "Sending #{@directory.path}"
      @client.puts @directory.path
    end

    # RCD path
    # Responds: path exists: OK
    #           path doesn't exist: FAILURE
    def command_rcd path
      new_path = path
      unless new_path.start_with?("/")
        new_path = @directory.path
        unless @directory.path.end_with?("/")
          new_path += "/"
        end
        new_path += path
      end

      puts "Change directory to #{new_path}"
      if Dir.exists?(new_path)
        @directories[@index] = Dir.new(new_path)
        @client.puts "OK"
      else
        @client.puts "FAILURE"
      end
    end

    # PUT filename filesize
    # Knows it will be retrieving the file over data connection
    def command_put filename, filesize
    end

    # GET filename
    # Responds: OK filesize
    def command_get filename
      # Respond with "OK #{filesize}"
      # Start sending file over data connection
    end

    # MPUT filename filesize [filename filesize]*
    # Knows it will be retrieving many files over data connection
    def command_mput files
    end

    # MGET filename [filename]*
    # Knows it will be sending many files over data connection
    def command_mget filenames
    end

    # RLS
    # Will send a newline delimited list over data connection
    def command_rls
    end
  end
end
