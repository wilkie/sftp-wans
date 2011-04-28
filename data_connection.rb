# The implementation of the Data Delivery Layer of SimpleFTP

module SFTP
  class DataConnection
    require 'digest/md5'
    require 'stringio'

    attr_accessor :options
    attr_accessor :stats

    DEFAULT_PORT = 8081

    DEFAULT_WINDOW_SIZE = 16
    DEFAULT_FRAME_SIZE = 16
    DEFAULT_IMPLEMENTATION = :select_repeat # Or :go_back
    DEFAULT_TIMEOUT = 0.5

    DEFAULT_DROP_RATE = 0.2
    DEFAULT_ERROR_RATE = 0.4

    def initialize options
      # stats

      @stats = {}

      clear_stats

      if options[:host]
        port = options[:port]
        port = DEFAULT_PORT if port.nil?
        @socket = TCPSocket.new options[:host], port
      elsif options[:socket]
        @socket = options[:socket]
      end

      set_options options
    end

    def clear_stats
      @stats[:corrupted] = 0
      @stats[:dropped] = 0
      @stats[:frames_sent] = 0
      @stats[:redundant_frames] = 0
      @stats[:frames_received] = 0
      @stats[:timeouts] = 0
    end

    def set_options options
      @options = {}

      options[:window_size] = options[:window_size].to_i unless options[:window_size].nil?
      @options[:window_size] = options[:window_size] || options["window_size"] || DEFAULT_WINDOW_SIZE
      options[:frame_size] = options[:frame_size].to_i unless options[:frame_size].nil?
      @options[:frame_size] = options[:frame_size] || options["frame_size"] || DEFAULT_FRAME_SIZE
      options[:implementation] ||= options[:implementation].intern unless options[:implementation].nil?
      options["implementation"] ||= options["implementation"].intern unless options["implementation"].nil?
      @options[:implementation] = options[:implementation] || options["implementation"] || DEFAULT_IMPLEMENTATION

      options[:timeout] = options[:timeout].to_f unless options[:timeout].nil?
      @options[:timeout] = options[:timeout] || options["timeout"] || DEFAULT_TIMEOUT

      options[:error_rate] = options[:error_rate].to_f unless options[:error_rate].nil?
      @options[:error_rate] = options[:error_rate] || options["error_rate"] || DEFAULT_ERROR_RATE

      options[:drop_rate] = options[:drop_rate].to_f unless options[:drop_rate].nil?
      @options[:drop_rate] = options[:drop_rate] || options["drop_rate"] || DEFAULT_DROP_RATE
    end

    # When something is on the line
    def ping
      if @type == :receiving
        # Receive packets
        header = @socket.readline
        header.match /^(\d+)\s+(.+)$/
        sequence_number = $1.to_i
        check = $2
        puts header

        # Receive data
        if not receive_frame sequence_number
          return
        end

        # Perform checksum
        sum = checksum sequence_number

        # Append to file and send ACK, or send NAK
        if sum == check
          acknowledge_frame sequence_number
        else
          puts "Corruption Detected"
          @stats[:corrupted] += 1
          nacknowledge_frame sequence_number
        end
      else
        # Respond to acknowledgments
        ack = @socket.readline
        puts "!!#{ack}"
        if ack.match /^ACK\s*(\d+)$/
          # Respond to ACK
          sequence_number = $1.to_i
          receive_acknowledgement sequence_number

          if (@delivered % (@options[:frame_size] * @options[:window_size])) == 0
            # window has been acknowledged
            #write_out_window
            send_next_window
          elsif @delivered >= @filesize
            stop_timeout
            #write_out_window
          end
        elsif ack.match /^NAK\s*(\d+)$/
          # Respond to NAK
          sequence_number = $1.to_i
          puts "Frame #{sequence_number} NAK"
          receive_nacknowledgement sequence_number
        end
      end
    end

    def timeout
      @stats[:timeouts] += 1
      if @type == :receiving
        # Timeout expecting a frame
        puts "Timeout on #{(@current_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))}"
        nacknowledge_frame (@current_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))
      else
        # Timeout expecting an ack
      end

      reset_timeout
    end

    def reset_timeout
      @expire_time = Time.now
    end

    def stop_timeout
      @expire_time = nil
    end

    def idle
      unless @expire_time.nil?
        elapsed = Time.now - @expire_time
        if elapsed >= @options[:timeout]
          timeout
        end
      end

      return if @file.nil?
      return if done?
      return if @type == :receiving

      # send next frame
      max_frame = (@window+1) * @options[:window_size]
      frame_count = (@filesize / @options[:frame_size])
      if @filesize % @options[:frame_size] != 0
        frame_count += 1
      end

      max_frame = [max_frame,frame_count].min

      if @current_frame < max_frame
        send_frame (@current_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))
        @current_frame += 1
      end
    end

    def contents
      # give the string contents of the file
      @file.seek 0
      @file.read @file.size
    end

    # Keep track of statistics about the transfer

    def checksum sequence_number
      Digest::MD5.hexdigest(@buffer[sequence_number])
    end

    # Initiate a transfer expecting to receive a file of a particular size
    def receive filename, filesize
      @type = :receiving
      
      # Open the file
      if filename.nil?
        # will be printing to screen
        @file = StringIO.new ""
      else
        puts "Opening #{filename} for writing..."
        @file = File.new filename, "w+"
      end
      @filesize = filesize

      puts "Receiving file (#{filesize} bytes)"

      # Set up how much do we currently have (outside of the window)
      @delivered = 0

      @window = 0
      @current_frame = 0
      @buffer = Array.new(@options[:window_size] * 2) { nil }

      reset_timeout

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
      @current_frame = 0

      @buffer = Array.new(@options[:window_size] * 2) { nil }

      reset_timeout

      send_window
    end

    def acknowledge_frame sequence_number
      puts "Acking #{sequence_number}"

      puts "#{@delivered} bytes delivered"
      @delivered += @options[:frame_size]

      # Can we write out something in our buffer?
      if @current_frame % (@options[:window_size] * 2) == sequence_number
        max_frame = @options[:window_size] * ((@window % 2) + 1)
        cur_seq_num = sequence_number

        while cur_seq_num < max_frame and not @buffer[cur_seq_num].nil? do
          # Get contents of the buffer
          buffer = @buffer[cur_seq_num]
          break if buffer == ""

          # Write out the buffer
          puts "WRITING #{@current_frame}"
          @file.write buffer

          # Clear memory
          @buffer[cur_seq_num] = ""

          # Consider the next frame
          cur_seq_num += 1
          @current_frame += 1
        end
      end

      if (@delivered % (@options[:frame_size] * @options[:window_size])) == 0
        puts "Window received."
        receive_next_window
      end

      if (sequence_number+1) == (@options[:window_size] * 2)
        @socket.puts "ACK 0"
      else
        @socket.puts "ACK #{sequence_number+1}"
      end

      if @delivered >= @filesize
        puts "Delivered"

        unless @file.is_a? StringIO
          stop_timeout
          @file.close
          @file = nil
        end
      end
    end

    def receive_acknowledgement sequence_number
      frame_acknowledged = sequence_number-1
      if frame_acknowledged == -1
        frame_acknowledged = (@options[:window_size] * 2) - 1
      end
      puts "Frame #{frame_acknowledged} ACK'd"

      frames_delivered = @delivered / @options[:frame_size]
      next_frame = frames_delivered % (@options[:window_size] * 2)

      cur_seq_num = frame_acknowledged
      max_frame = @options[:window_size] * ((@window % 2) + 1)

      # clear memory
      return if @buffer[cur_seq_num] == ""
      @buffer[cur_seq_num] = ""

#      while @delivered < @filesize and cur_seq_num < max_frame and @buffer[cur_seq_num].length == 0 do
        # append to file and up the delivered count
        @delivered += @options[:frame_size]

        cur_seq_num += 1
 #     end

      # we received a response, so good
      reset_timeout

      puts "#{@delivered} bytes sent successfully."
      cur_seq_num
    end

    def nacknowledge_frame sequence_number
      @buffer[sequence_number] = nil
      @socket.puts "NAK #{sequence_number}"
    end

    def receive_nacknowledgement sequence_number
      # resend frame

      if @options[:implementation] == :go_back
        @current_frame = sequence_number
      else
        send_frame sequence_number
      end
    end

    def done?
      @delivered >= @filesize
    end

    def receive_frame sequence_number
      @stats[:frames_received] += 1

      # Read in the frame
      to_read = @options[:frame_size]
      if ((@window * @options[:window_size]) + (sequence_number % @options[:window_size]) + 1) * @options[:frame_size] >= @filesize
        to_read = @filesize % @options[:frame_size]
        to_read = @options[:frame_size] if to_read == 0
      end

      buffer = @socket.read(to_read)
      if not @buffer[sequence_number].nil?
        # Already have this frame
        puts "Redundant frame #{sequence_number}"
        @stats[:redundant_frames] += 1
        return false
      end

      puts "Reading frame #{sequence_number} (#{to_read} bytes)"
      @buffer[sequence_number] = buffer

      reset_timeout

      return true
    end

    def receive_window
      @options[:window_size].times do |i|
        @buffer[i + ((@window % 2) * @options[:window_size])] = nil
      end
    end

    def receive_next_window
      @window += 1
      receive_window
    end

    def send_frame sequence_number
      puts "Sending frame #{sequence_number}"
      @stats[:frames_sent] += 1

      if rand(100) < @options[:drop_rate] * 100
        @stats[:dropped] += 1
        puts "Dropped frame"
        return
      end

      # send from buffer
      @socket.puts "#{sequence_number} #{checksum sequence_number}"

      to_send = String.new(@buffer[sequence_number])
      if rand(100) < @options[:error_rate] * 100
        @stats[:corrupted] += 1
        puts to_send.length
        puts to_send.getbyte(0)
        to_send.setbyte(0, to_send.getbyte(0) ^ 255)
      end

      # timeout for acknowledgement
      reset_timeout
      @socket.write to_send

      puts "Sent frame #{sequence_number}"
    end

    def send_next_frame sequence_number
      # pull from file into buffer
      frames_delivered = @delivered / @options[:frame_size]
      
      # Get number of bytes delivered (floors @delivery)
      bytes_sent = frames_delivered * @options[:frame_size]

      # Assume previous frames were sent
      bytes_sent += (sequence_number - ((@window % 2) * @options[:window_size])) * @options[:frame_size]

      if bytes_sent >= @filesize
        return
      end

      to_read = [@options[:frame_size], @filesize - bytes_sent].min
      puts "Sending #{to_read} bytes"
      @buffer[sequence_number] = @file.read(to_read)
    end

    def send_window
      # set the frames for this window to nil (preserve the last window)
      @options[:window_size].times do |i|
        @buffer[i + ((@window % 2) * @options[:window_size])] = nil
      end

      # Send frames
      @options[:window_size].times do |i|
        send_next_frame i + ((@window % 2) * @options[:window_size])
      end
    end

    def write_out_window
      @options[:window_size].times do |i|
        idx = i + ((@window % 2) * @options[:window_size])
        unless @buffer[idx].nil?
          @file.write @buffer[idx]
        end
      end
    end

    # Send the next window
    def send_next_window
      @window += 1
      send_window
    end
  end
end
