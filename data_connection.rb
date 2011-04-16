# The implementation of the Data Delivery Layer of SimpleFTP

module SFTP
  class DataConnection
    require 'digest/md5'

    DEFAULT_PORT = 8081

    DEFAULT_WINDOW_SIZE = 4
    DEFAULT_FRAME_SIZE = 4
    DEFAULT_IMPLEMENTATION = :select_repeat # Or :go_back

    def initialize options
      if options[:host]
        port = options[:port]
        port = DEFAULT_PORT if port.nil?
        @socket = TCPSocket.new options[:host], port
      elsif options[:socket]
        @socket = options[:socket]
      end

      @window_size = options[:window_size] || DEFAULT_WINDOW_SIZE
      @frame_size = options[:frame_size] || DEFAULT_FRAME_SIZE
      @implementation = options[:algorithm] || DEFAULT_IMPLEMENTATION
    end

    # When something is on the line
    def ping
      if @type == :receiving
        # Receive packets
        header = @socket.readline
        header.match /^(\d+)\s+(.+)$/
        sequence_number = $1.to_i
        check = $2

        # Receive data
        receive_frame sequence_number

        # Perform checksum
        sum = checksum sequence_number

        # Append to file and send ACK, or send NAK
        if sum == check
          acknowledge_frame sequence_number
        else
          nacknowledge_frame sequence_number
        end
      else
        # Respond to acknowledgments
        ack = @socket.readline
        if ack.match /^ACK\s*(\d+)$/
          # Respond to ACK
          sequence_number = $1.to_i
          receive_acknowledgement sequence_number

          if (sequence_number % @window_size) == 0
            # window has been acknowledged
            send_next_window
          end
        elsif ack.match /^NAK\s*(\d+)$/
          # Respond to NAK
          sequence_number = $1.to_i
          puts "Frame #{sequence_number} NAK"
        end
      end
    end

    # Keep track of statistics about the transfer

    def checksum sequence_number
      Digest::MD5.hexdigest(@buffer[sequence_number])
    end

    # Initiate a transfer expecting to receive a file of a particular size
    def receive filename, filesize
      @type = :receiving
      
      # Open the file
      puts "Opening #{filename} for writing..."
      @file = File.new filename, "w+"
      @filesize = filesize

      puts "Receiving file (#{filesize} bytes)"

      # Set up how much do we currently have (outside of the window)
      @delivered = 0

      @window = 0
      receive_window
    end

    # Initiate a transfer where we are responsible for sending the file
    def transfer file
      @type = :sending
      @file = file
      @filesize = file.size

      puts "Sending file (#{file.size} bytes)"

      # Set up how much do we currently have (outside of the window)
      @delivered = 0

      # window number
      @window = 0

      send_window
    end

    def acknowledge_frame sequence_number
      frames_delivered = @delivered / @frame_size
      next_frame = frames_delivered % (@window_size * 2)

      if next_frame == sequence_number
        # append to file
        cur_seq_num = sequence_number
        while @delivered < @filesize and cur_seq_num < (@window_size*2) and not @buffer[cur_seq_num].nil? do
          # put out buffer contents
          buffer = @buffer[cur_seq_num]

          # append to file and up the delivered count
          @delivered += buffer.length
          @file.write buffer

          # clear memory
          @buffer[cur_seq_num] = ""

          cur_seq_num += 1
        end
      end

      if (sequence_number+1) % @window_size == 0
        puts "Window received."
        receive_next_window
      end

      if (sequence_number+1) == (@window_size * 2)
        @socket.puts "ACK 0"
      else
        @socket.puts "ACK #{sequence_number+1}"
      end

      if @delivered == @filesize
        puts "Delivered"
        @file.close
      end
    end

    def receive_acknowledgement sequence_number
      frame_acknowledged = sequence_number-1
      if frame_acknowledged == -1
        frame_acknowledged = (@window_size * 2) - 1
      end
      puts "Frame #{frame_acknowledged} ACK'd"

      frames_delivered = @delivered / @frame_size
      next_frame = frames_delivered % (@window_size * 2)

      if next_frame == frame_acknowledged
        cur_seq_num = frame_acknowledged
#        while @delivered < @filesize and cur_seq_num < @window_size and @buffer[cur_seq_num] do
          # put out buffer contents
          buffer = @buffer[cur_seq_num]

          # append to file and up the delivered count
          @delivered += buffer.length

          # clear memory
          @buffer[cur_seq_num] = ""

          cur_seq_num += 1
 #       end
      end

      puts "#{@delivered} bytes sent successfully."
    end

    def nacknowledge_frame sequence_number
      @socket.puts "NAK #{sequence_number}"
    end

    def done?
      @delivered == @filesize
    end

    def receive_frame sequence_number
      if not @buffer[sequence_number].nil?
        # Already have this frame
        puts "Redundant frame #{sequence_number}"
        return
      end

      # Read in the frame
      to_read = [@frame_size, @filesize - @delivered].min
      puts "Reading frame #{sequence_number} (#{to_read} bytes)"
      @buffer[sequence_number] = @socket.read(to_read)
    end

    def receive_window
      if (@window % 2) == 0
        @buffer = Array.new(@window_size * 2) { nil }
      end
    end

    def receive_next_window
      @window += 1
      receive_window
    end

    def send_frame sequence_number
      puts "Sending frame #{sequence_number}"
      # send from buffer
      @socket.puts "#{sequence_number} #{checksum sequence_number}"
      @socket.write @buffer[sequence_number]

      puts "Sent frame #{sequence_number}"
    end

    def send_next_frame sequence_number
      # pull from file into buffer
      frames_delivered = @delivered / @frame_size
      
      # Get number of bytes delivered (floors @delivery)
      bytes_sent = frames_delivered * @frame_size
      # Assume previous frames were sent
      bytes_sent += (sequence_number - ((@window % 2) * @window_size)) * @frame_size

      if bytes_sent >= @filesize
        return
      end

      to_read = [@frame_size, @filesize - bytes_sent].min
      @buffer[sequence_number] = @file.read(to_read)

      send_frame sequence_number
    end

    def send_window
      if (@window % 2) == 0
        @buffer = Array.new(@window_size * 2) { nil }
      end

      @window_size.times do |i|
        send_next_frame i + ((@window % 2) * @window_size)
      end
    end

    def send_next_window
      @window += 1
      send_window
    end
  end
end
