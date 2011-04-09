require_relative 'server'

module SFTP
  class Client
    def initialize(host, port = SFTP::Server::DEFAULT_PORT)
      @socket = TCPSocket.new(host, port)
    end

    def send
      @socket.puts "hello"
    end

    def command_pwd
       @socket.puts "PWD"
       @socket.readline
    end

    def command_rcd path
      @socket.puts "RCD #{path}"
      @socket.readline
    end

    def command_rls
      @socket.puts "RLS"
      # Wait for data to be sent
    end

    def command_get filename
      @socket.puts "GET #{filename}"
      # Wait for data to be sent
    end

    def command_mget filenames
      @socket.puts "MGET #{files.inject(""){|l,e| l = "#{l}#{e} "}}"
      # Wait for data to be sent
    end

    def command_put filename
      # XXX: Get filesize
      filesize = 0
      @socket.puts "PUT #{filename} #{filesize}"
    end

    def command_mput filenames
      @socket.puts "MGET #{files.inject(""){|l,e| l = "#{l}#{e} "}}"
      # Wait for data to be sent
    end

    def command_lcd path
      # XXX: handle error
      Dir.chdir path
    end

    def command_lls
      # Return list
    end
  end
end
