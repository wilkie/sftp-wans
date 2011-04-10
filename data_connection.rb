module SFTP
  class DataConnection
    DEFAULT_PORT = 8081

    def initialize options
      if options[:host]
        port = options[:port]
        port = DEFAULT_PORT if port.nil?
        @socket = TCPSocket.new options[:host], port
      elsif options[:socket]
        @socket = options[:socket]
      end
    end

    def receive filename, filesize
      puts "Receiving file (#{filesize} bytes)"
    end

    def transfer file
      puts "Sending file (#{file.size} bytes)"
    end
  end
end
