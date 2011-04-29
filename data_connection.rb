# The implementation of the Data Delivery Layer of SimpleFTP

module SFTP
  class DataConnection
    require 'digest/md5'
    require 'stringio'

    # Properties

    attr_accessor :options
    attr_accessor :stats

    # Various defaults for the DataConnection variables

    DEFAULT_PORT = 8081

    DEFAULT_WINDOW_SIZE = 16
    DEFAULT_FRAME_SIZE = 16
    DEFAULT_IMPLEMENTATION = :go_back
    DEFAULT_TIMEOUT = 0.5

    DEFAULT_DROP_RATE = 0.2
    DEFAULT_ACK_DROP_RATE = 0.1
    DEFAULT_ERROR_RATE = 0.4

    # Establish a Data Connection
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

    # Clear statistics
    def clear_stats
      @stats[:corrupted] = 0
      @stats[:frames_dropped] = 0
      @stats[:frames_sent] = 0
      @stats[:redundant_frames] = 0
      @stats[:frames_received] = 0
      @stats[:timeouts] = 0
      @stats[:out_of_order] = 0
      @stats[:avg_buffer_len] = 0
      @stats[:acks_dropped] = 0
      @stats[:acks_sent] = 0
      @stats[:acks_received] = 0
      @stats[:naks_dropped] = 0
      @stats[:naks_sent] = 0
      @stats[:naks_received] = 0
    end

    # Reset variables
    def set_options options
      @options = {}

      options[:window_size] = options[:window_size].to_i unless options[:window_size].nil?
      @options[:window_size] = options[:window_size] || options["window_size"] || DEFAULT_WINDOW_SIZE
      options[:frame_size] = options[:frame_size].to_i unless options[:frame_size].nil?
      @options[:frame_size] = options[:frame_size] || options["frame_size"] || DEFAULT_FRAME_SIZE
      options[:implementation] = options[:implementation].intern unless options[:implementation].nil?
      options["implementation"] = options["implementation"].intern unless options["implementation"].nil?
      @options[:implementation] = options[:implementation] || options["implementation"] || DEFAULT_IMPLEMENTATION

      options[:timeout] = options[:timeout].to_f unless options[:timeout].nil?
      @options[:timeout] = options[:timeout] || options["timeout"] || DEFAULT_TIMEOUT

      options[:error_rate] = options[:error_rate].to_f unless options[:error_rate].nil?
      @options[:error_rate] = options[:error_rate] || options["error_rate"] || DEFAULT_ERROR_RATE

      options[:ack_drop_rate] = options[:ack_drop_rate].to_f unless options[:ack_drop_rate].nil?
      @options[:ack_drop_rate] = options[:ack_drop_rate] || options["ack_drop_rate"] || DEFAULT_ACK_DROP_RATE

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

        # ACK anything if we have received the file
        if done?
          response = receive_frame sequence_number

          @stats[:acks_sent] += 1
          if (sequence_number+1) == (@options[:window_size] * 2)
            @socket.puts "ACK 0"
          else
            @socket.puts "ACK #{sequence_number+1}"
          end

          return
        end

        # Receive data
        response = receive_frame sequence_number
        if response == :redundant
          puts "Reacknowledge!"
          acknowledge_frame sequence_number
          return
        end

        # Perform checksum
        if response != :illegal
          sum = checksum sequence_number
        end

        # Append to file and send ACK, or send NAK
        if response == :illegal
          puts "Out of order frame #{sequence_number}"
          @stats[:out_of_order] += 1

          max_frame = @options[:window_size] * ((@window % 2) + 1)

          blah_frame = @next_frame % (@options[:window_size] * 2)
          blah_frame = (@options[:window_size]*2) if blah_frame == 0 and max_frame == (@options[:window_size]*2)
          nacknowledge_frame blah_frame
        elsif sum == check
          acknowledge_frame sequence_number
        else
          puts "Corruption Detected"
          @stats[:corrupted] += 1
          nacknowledge_frame sequence_number
        end
      else
        return if done?

        # Respond to acknowledgments
        ack = @socket.readline

        if ack.match /^ACK\s*(\d+)$/
          # Respond to ACK
          sequence_number = $1.to_i
          receive_acknowledgement sequence_number

          max_frame = @options[:window_size] * ((@window % 2) + 1)

          blah_frame = @next_frame % (@options[:window_size] * 2)
          blah_frame = (@options[:window_size]*2) if blah_frame == 0 and max_frame == (@options[:window_size]*2)
          if blah_frame == max_frame
            # window has been acknowledged
            send_next_window
          elsif @delivered >= @filesize
            stop_timeout
          end
        elsif ack.match /^NAK\s*(\d+)$/
          # Respond to NAK
          sequence_number = $1.to_i
          puts "Frame #{sequence_number} NAK"
          receive_nacknowledgement sequence_number
        end
      end
    end

    # Called upon a timeout
    def timeout
      return if @file.nil?
      return if done?

      reset_timeout

      @stats[:timeouts] += 1
      if @type == :receiving
        # Timeout expecting a frame
        expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))
        puts "Timeout on #{expected_frame}"
        nacknowledge_frame expected_frame
      else
        # Timeout expecting an ack
        expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))

        # Resend the first frame to not be ack'd
        if @buffer[expected_frame] == ""
          # it is acked, wtf
          return
        end
        puts "Resending #{expected_frame}"
        send_frame expected_frame
      end
    end

    # Allow timeouts
    def start_timeout
      @expire_time = Time.now
    end

    # Restart the timer
    def reset_timeout
      @expire_time = Time.now unless @expire_time.nil?
    end

    # Stop timeouts from occurring
    def stop_timeout
      @expire_time = nil
    end

    # During idle time, a timeout may occur or a frame might be sent
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

    # After a file is transferred, this function can give the contents
    # to you. This is used to display the contents of a directory when
    # RLS is used.
    def contents
      # give the string contents of the file
      @file.seek 0
      @file.read @file.size
    end

    # Determine the checksum using MD5 hash
    def checksum sequence_number
      Digest::MD5.hexdigest(@buffer[sequence_number])
    end

    # Initiate a transfer expecting to receive a file of a particular size
    def receive filename, filesize
      stop_timeout

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
      @next_frame = 0
      @sum_buffer_len = 0
      @max_buffer_len = 0
      @buffer_len = 0

      @buffer = Array.new(@options[:window_size] * 2) { nil }
      @sent = Array.new(@options[:window_size] * 2) { 0 }

      start_timeout

      receive_window
    end

    # Initiate a transfer where we are responsible for sending the file
    def transfer file
      stop_timeout

      @type = :sending
      @file = file
      @filesize = file.size

      puts "Sending file (#{file.size} bytes)"

      # Set up how much do we currently have (outside of the window)
      @delivered = 0

      # window number
      @window = 0
      @current_frame = 0
      @next_frame = 0
      @sum_buffer_len = 0
      @max_buffer_len = 0
      @buffer_len = 0

      @buffer = Array.new(@options[:window_size] * 2) { nil }
      @sent = Array.new(@options[:window_size] * 2) { 0 }

      start_timeout

      send_window
    end

    # This will acknowledge the given frame
    def acknowledge_frame sequence_number
      @stats[:acks_sent] += 1

      puts "Acking #{sequence_number}"

      expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))
      max_frame = @options[:window_size] * ((@window % 2) + 1)

      # Can we write out something in our buffer?
      if expected_frame == sequence_number
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
          @buffer_len -= 1 if @options[:implementation] == :selective_repeat

          # Consider the next frame
          cur_seq_num += 1
          @current_frame += 1
          @next_frame += 1 
          @delivered += @options[:frame_size]
        end
      end

#      if (@delivered % (@options[:frame_size] * @options[:window_size])) == 0
      blah_frame = @next_frame % (@options[:window_size] * 2)
      blah_frame = (@options[:window_size]*2) if blah_frame == 0 and max_frame == (@options[:window_size]*2)
      if blah_frame == max_frame
        puts "Window received."
        receive_next_window
      end

      if drop_ack? and not done?
        puts "Dropping Ack"
        @stats[:acks_dropped] += 1
        return
      end

      if (sequence_number+1) == (@options[:window_size] * 2)
        @socket.puts "ACK 0"
      else
        @socket.puts "ACK #{sequence_number+1}"
      end

      if @delivered >= @filesize
        puts "Delivered"
        done

        unless @file.is_a? StringIO
          stop_timeout
          @file.close
          @file = nil
        end
      end
    end

    # Called when transfer completes
    def done
      @stats[:avg_buffer_len] = @sum_buffer_len / (@window+1)
    end

    def perform_acknowledgement frame_acknowledged
      expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))

      frames_delivered = @delivered / @options[:frame_size]
      next_frame = frames_delivered % (@options[:window_size] * 2)

      max_frame = @options[:window_size] * ((@window % 2) + 1)
      min_frame = @options[:window_size] * ((@window % 2))

      # Don't care if outside of the sending window
      return if frame_acknowledged >= max_frame or frame_acknowledged < min_frame

      if @options[:implementation] == :go_back and frame_acknowledged > expected_frame
        puts "Cumulative Acknowledgement #{frame_acknowledged} > #{expected_frame}"
        # Ack all from expected_frame to frame_acknowledged
        (expected_frame..frame_acknowledged-1).each do |i|
          perform_acknowledgement i
        end

        expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))

        frames_delivered = @delivered / @options[:frame_size]
        next_frame = frames_delivered % (@options[:window_size] * 2)
      end

      cur_seq_num = frame_acknowledged
      max_frame = @options[:window_size] * ((@window % 2) + 1)

      # clear memory
      return if @buffer[cur_seq_num] == ""
      @buffer[cur_seq_num] = ""
      @buffer_len -= 1

      # we received a response, so good
      reset_timeout

      # append to file and up the delivered count
      @delivered += @options[:frame_size]
      @next_frame += 1 if @options[:implementation] == :go_back
      @current_frame = @next_frame if @options[:implementation] == :go_back

      blah_frame = @next_frame % (@options[:window_size] * 2)
      blah_frame = (@options[:window_size]*2) if blah_frame == 0 and max_frame == (@options[:window_size]*2)
      if @options[:implementation] == :selective_repeat and frame_acknowledged == blah_frame
        # determine the next frame we expect an ACK for
        while blah_frame < max_frame and @buffer[blah_frame] == ""
          @next_frame += 1
          blah_frame = @next_frame % (@options[:window_size] * 2)
          blah_frame = (@options[:window_size]*2) if blah_frame == 0 and max_frame == (@options[:window_size]*2)
        end
      end

      cur_seq_num += 1

      if done?
        done
      end

      cur_seq_num
    end

    # This is called when an ACK is received
    def receive_acknowledgement sequence_number
      @stats[:acks_received] += 1

      frame_acknowledged = sequence_number-1
      if frame_acknowledged == -1
        frame_acknowledged = (@options[:window_size] * 2) - 1
      end
      puts "Frame #{frame_acknowledged} ACK'd"

      perform_acknowledgement frame_acknowledged
    end

    # Send a NAK to indicate failure to receive a frame
    def nacknowledge_frame sequence_number
      @stats[:naks_sent] += 1

      # Already acked?
      return if @buffer[sequence_number] == ""

      @buffer[sequence_number] = nil

      # If GO_BACK_N algorithm, then we expect to receive all of the
      # frames again
      expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))

      if @options[:implementation] == :go_back
        next_frame = ((@window * @options[:window_size]) + (sequence_number % @options[:window_size]))
        @next_frame = [next_frame, @next_frame].min
        @current_frame = @next_frame

        # Undo work done
        
        max_frame = @options[:window_size] * ((@window % 2) + 1)
        (expected_frame+1..max_frame).each do |i|
          @buffer[i] = nil
        end
      end

      if drop_ack?
        @stats[:naks_dropped] += 1
        puts "Dropped NAK"
        return
      end

      @socket.puts "NAK #{sequence_number}"

      # we received a response, so good
      reset_timeout
    end

    # This is called when a NAK is received
    def receive_nacknowledgement sequence_number
      @stats[:naks_received] += 1

      if @buffer[sequence_number] == ""
        return
      end

      # resend frame

      expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))
      max_frame = @options[:window_size] * ((@window % 2) + 1)
      min_frame = @options[:window_size] * ((@window % 2))

      if sequence_number >= max_frame or sequence_number < min_frame
        return
      end

      if @options[:implementation] == :go_back
        next_frame = ((@window * @options[:window_size]) + (sequence_number % @options[:window_size]))
        @next_frame = [next_frame, @next_frame].min
        @current_frame = @next_frame

        # Undo work done
        
        max_frame = @options[:window_size] * ((@window % 2) + 1)
      else
        send_frame sequence_number
      end
    end

    # This will tell you if the transfer is complete.
    def done?
      @delivered >= @filesize
    end

    # Receive a frame from the socket.
    def receive_frame sequence_number
      @stats[:frames_received] += 1

      # Read in the frame
      to_read = @options[:frame_size]
      if ((@window * @options[:window_size]) + (sequence_number % @options[:window_size]) + 1) * @options[:frame_size] >= @filesize
        to_read = @filesize % @options[:frame_size]
        to_read = @options[:frame_size] if to_read == 0
      end

      buffer = @socket.read(to_read)

      # Is it from another window? We can ack these
      max_frame = @options[:window_size] * ((@window % 2) + 1)
      min_frame = @options[:window_size] * ((@window % 2))
      if sequence_number >= max_frame or sequence_number < min_frame
        # assume last window
        return :redundant
      end

      expected_frame = (@next_frame % @options[:window_size]) + (@options[:window_size] * (@window % 2))
      if @options[:implementation] == :go_back and sequence_number != expected_frame
        puts "Out of order frame! #{sequence_number} != #{expected_frame}"
        return :illegal
      end

      if not @buffer[sequence_number].nil?
        # Already have this frame
        puts "Redundant frame #{sequence_number}"
        @stats[:redundant_frames] += 1
        return :redundant
      end

      reset_timeout

      @buffer[sequence_number] = buffer
      @buffer_len += 1 if @options[:implementation] == :selective_repeat
      if @buffer_len > @max_buffer_len
        @max_buffer_len = @buffer_len
      end

      return :received
    end

    # Called to clear the buffers for a new window.
    def receive_window
      @sum_buffer_len += @max_buffer_len
      @foo = (@foo || 0) + 1

      @max_buffer_len = 0
      @buffer_len = 0

      @next_frame = (@window * @options[:window_size])

      @options[:window_size].times do |i|
        @buffer[i + ((@window % 2) * @options[:window_size])] = nil
      end
    end

    # Called when a new window is to be received.
    def receive_next_window
      @window += 1
      receive_window
    end

    def drop?
      rand(100) < @options[:drop_rate] * 100
    end

    def drop_ack?
      rand(100) < @options[:ack_drop_rate] * 100
    end

    # Sends the given frame
    def send_frame sequence_number
      if @sent[sequence_number] == 0
        @sent[sequence_number] = 1
        @buffer_len += 1

        if @buffer_len > @max_buffer_len
          @max_buffer_len = @buffer_len
        end
      end

      puts "Sending frame #{sequence_number}"
      @stats[:frames_sent] += 1

      if drop?
        @stats[:frames_dropped] += 1
        puts "Dropped Frame"
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
    end

    # Reads in the frame from the file into the buffer.
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
      @buffer[sequence_number] = @file.read(to_read)
    end

    def send_window
      @sum_buffer_len += @max_buffer_len
      @foo = (@foo || 0) + 1

      @max_buffer_len = 0
      @buffer_len = 0

      # set the frames for this window to nil (preserve the last window)
      @options[:window_size].times do |i|
        @buffer[i + ((@window % 2) * @options[:window_size])] = nil
        @sent[i + ((@window % 2) * @options[:window_size])] = 0
      end

      @next_frame = (@window * @options[:window_size])

      # Send frames
      @options[:window_size].times do |i|
        send_next_frame i + ((@window % 2) * @options[:window_size])
      end
    end

    # Will write out a window's worth of the buffer to the file.
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
