require_relative 'server'
require_relative 'name_server'

module SFTP
  class Client
    def initialize (config = nil, host = nil, port = SFTP::Server::DEFAULT_PORT)
      @config = config
      if config
        @nameserver = config["nameserver"]
        puts @nameserver
      end
      unless host.nil?
        command_open host, port
      end
    end

    def command_open host, port = SFTP::Server::DEFAULT_PORT, data_port = nil
      if host.match /^\d*\.\d*(?:\.\d*\.\d*)?$/
        # is IP
      else
        # is name
        # Contact name server
        @config["nameserver"].match /^(.*):(.*)$/
        nameserver_host = $1
        nameserver_port = $2

        name_server = NameServer.new(nameserver_port, nameserver_host)
        old_host = host
        ip = name_server.resolve host
        host = ip.first
        port = ip.last

        puts "Resolved #{old_host} to #{host}:#{port}"

        name_server.close
      end

      unless @socket.nil?
        command_close
      end
      begin
        @socket = TCPSocket.new(host, port)
      rescue
      end
      if @socket.nil? or @socket.closed?
        "Connection Failed"
      else
        data_response = ""
        if not data_port.nil?
          data_listener = TCPServer.new(data_port)

          @socket.puts "OPEN #{data_port}"
          select([data_listener])
          @data_socket = data_listener.accept
          data_response = "Data Connection Made\n"
          data_listener.close
          response = @socket.readline
        else
          @socket.puts "OPEN"
          response = @socket.readline
          data_port = response[/^OK (.*)$/,1].to_i
          @data_socket = TCPSocket.new host, data_port
        end
        @data_connection = DataConnection.new({:socket=>@data_socket}.merge(@config))

        "#{data_response}Connection Made: #{response}"
      end
    end

    def command_close
      unless @socket.nil?
        @socket.close
        @socket = nil
        @data_socket.close
        @data_socket = nil
        "Connection Closed"
      else
        "Connection Not Open"
      end
    end

    def closed?
      @socket.nil? or @socket.closed?
    end

    def command_pwd
      return "Connection Not Open" if closed?
      @socket.puts "PWD"
      @socket.readline
    end

    def command_rcd path
      return "Connection Not Open" if closed?
      @socket.puts "RCD #{path}"
      @socket.readline
    end

    def command_rls
      return "Connection Not Open" if closed?
      @socket.puts "RLS"

      # Wait for data to be sent
      # Get filesize
      response = @socket.readline
      if response.match /^OK/
        filesize = response[/OK (.*)$/,1].to_i
        @data_connection.receive(nil, filesize)
      end

      while not @data_connection.done? do
        socket = select([@data_socket], nil, nil, 0)
        unless socket.nil?
          socket = socket.first.first
        end

        if socket == @data_socket
          @data_connection.ping
        else
          @data_connection.idle
        end
      end

      @data_connection.contents
    end

    def command_get filename
      return "Connection Not Open" if closed?

      @socket.puts "GET #{filename}"
      # Get filesize
      response = @socket.readline
      if response.match /^OK/
        filesize = response[/OK (.*)$/,1].to_i
        # Wait for data to be sent
        @data_connection.receive(filename, filesize)
      end

      while not @data_connection.done? do
        socket = select([@data_socket], nil, nil, 0)
        unless socket.nil?
          socket = socket.first.first
        end

        if socket == @data_socket
          @data_connection.ping
        else
          @data_connection.idle
        end
      end

      response
    end

    def command_mget *filenames
      return "Connection Not Open" if closed?

      filenames.each do |f|
        command_get f
        # Wait for data to be sent
      end

      "Transfer complete."
    end

    def command_put filename
      return "Connection Not Open" if closed?
      local_filename = Server.absolute_path(Dir.getwd, filename)
      file = File.new(local_filename, "rb")
      @socket.puts "PUT #{filename} #{file.size}"
      response = @socket.readline

      @data_connection.transfer(file)

      while not @data_connection.done? do
        socket = select([@data_socket], nil, nil, 0)
        unless socket.nil?
          socket = socket.first.first
        end

        if socket == @data_socket
          @data_connection.ping
        else
          @data_connection.idle
        end
      end
      
      "Transfer complete."
    end

    def command_mput *filenames
      return "Connection Not Open" if closed?

      filenames.each do |f|
        command_put f
        # Wait for data to be sent
      end

      "Transfer complete."
    end

    def command_lcd path
      new_path = path

      # construct absolute path

      unless new_path.start_with?("/")
        new_path = Dir.getwd
        unless new_path.end_with?("/")
          new_path += "/"
        end
        new_path += path
      end

      new_path = SFTP::Server.sanitize new_path

      if Dir.exists?(new_path)
        Dir.chdir new_path
        "Changed directory to #{new_path}"
      else
        "Directory Not Found"
      end
    end

    def command_lls
      # Return list
      list = Dir.new(Dir.getwd).each.map do |entry|
        entry
      end
      list.delete "."
      list.delete ".."
      list
    end

    def command_clear_stats
      @data_connection.clear_stats
    end

    def command_stat stat=nil
      if stat.nil?
        @data_connection.stats
      else
        @data_connection.stats[stat.intern]
      end
    end

    def command_server_stat stat=nil
      return "Connection Not Open" if closed?

      @socket.puts "STAT #{stat}"

      @socket.readline
    end
    
    def command_config var=nil, val=nil
      if var.nil?
        if !closed?
          return @data_connection.options
        else
          return @config
        end
      end
      if val.nil?
        return @config[var.intern] || @config[var] unless @config.nil?
      end
      # Set @config[:var]=val
      @config[var.intern] = val
      # if already open then pass to server
      if !closed?
        @socket.puts "CONFIG #{var} #{val}"
        @data_connection.set_options @config
      end 
    end
    
  end
end
