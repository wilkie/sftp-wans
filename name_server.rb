require 'socket'

module SFTP
  class NameServer
    DEFAULT_PORT = 8089

    def initialize port = DEFAULT_PORT, host = nil
      if host.nil?
        @names = {}
        @clients = []
        @listener = TCPServer.new(port)
      else
        # abstraction to a name server client
        @socket = TCPSocket.new(host, port)
      end
    end

    def resolve name
      if @socket
        @socket.puts "GET #{name}"
        # Get result
        result = @socket.readline
        result.match /^(.*):(.*)$/
        [$1, $2.to_i]
      else
        nil
      end
    end

    def close
      @socket.close
      @socket = nil
    end

    def assign name, port
      if @socket
        host = @socket.addr.last
        @socket.puts "SET #{name} #{host}:#{port}"
        # Get result
        @socket.readline
      else
        nil
      end
    end

    def run
      while true do
        selected = select([@listener] + @clients)
        next if selected.nil?

        selected = selected.first
        next if selected.nil?

        selected.each do |socket|
          if socket == @listener
            puts "New Connection"
            client = @listener.accept
            @clients << client
          elsif @clients.include? socket
            @index = @clients.index socket
            @clients.delete socket

            begin
              if socket.closed? || socket.eof?
                puts "Client #{@index} closed"
                socket.close
              else
                # read command
                command = socket.readline
                puts command

                if command.downcase.start_with?("set ")
                  puts "Set"
                  string = command[4..-1]

                  # set value
                  # name IP:PORT
                  string.match /^(.*?)\s+(.*?)\n$/
                  @names[$1] = $2
                  puts "Setting #{$1} to #{$2}"

                  socket.puts "OK"
                elsif command.downcase.start_with?("get ")
                  string = command[4..-2]

                  # send value
                  # IP:PORT
                  socket.puts @names[string]
                  puts "Returing for #{string} value #{@names[string]}"
                end
              #rescue
              # Just close the socket
              # puts "Client #{@index} closed"
              # @clients.delete_at @index
              # @directories.delete_at @index
              # socket.close
              end
            end
          end
        end
      end
    end
  end
end
