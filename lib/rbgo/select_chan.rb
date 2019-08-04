require 'thread'

module Rbgo
  module Channel
    module Chan

      def self.new(max = 0)
        if max <= 0
          NonBufferChan.new
        else
          BufferChan.new(max)
        end
      end

      private

      attr_accessor :io_r, :io_w

      def notify
        tmp                  = io_w
        self.io_r, self.io_w = IO.pipe
        tmp.close
      end
    end

    # NonBufferChan
    #
    #
    #
    #
    #
    class NonBufferChan
      include Chan

      def initialize
        self.enq_mutex             = Mutex.new
        self.deq_mutex             = Mutex.new
        self.enq_cond              = ConditionVariable.new
        self.deq_cond              = ConditionVariable.new
        self.resource_array        = []
        self.close_flag            = false
        self.have_enq_waiting_flag = false
        self.have_deq_waiting_flag = false

        self.io_r, self.io_w = IO.pipe
      end

      def push(obj, nonblock = false)
        if closed?
          raise ClosedQueueError.new
        end

        if nonblock
          raise ThreadError.new unless enq_mutex.try_lock
        else
          enq_mutex.lock
        end

        begin
          if nonblock
            raise ThreadError.new unless have_deq_waiting_flag
          end

          begin
            if closed?
              raise ClosedQueueError.new
            else
              deq_mutex.synchronize do
                resource_array[0] = obj
                enq_cond.signal
                until resource_array.empty? || closed?
                  self.have_enq_waiting_flag = true

                  begin
                    Thread.new do
                      deq_mutex.synchronize do
                        # no op
                      end
                      notify
                    end
                  rescue Exception => ex
                    STDERR.puts ex
                    sleep 1
                    retry
                  end

                  deq_cond.wait(deq_mutex)
                end
                raise ClosedQueueError.new if closed?
              end
            end
          ensure
            self.have_enq_waiting_flag = false
          end
        ensure
          enq_mutex.unlock
        end

        self
      end

      def pop(nonblock = false)
        resource = nil
        ok       = true
        if closed?
          return [nil, false]
        end

        if nonblock
          raise ThreadError.new unless deq_mutex.try_lock
        else
          deq_mutex.lock
        end

        begin
          if nonblock
            raise ThreadError.new unless have_enq_waiting_flag
          end

          while resource_array.empty? && !closed?
            self.have_deq_waiting_flag = true
            notify
            enq_cond.wait(deq_mutex)
          end
          resource = resource_array.first
          ok       = false if resource_array.empty?
          resource_array.clear
          self.have_deq_waiting_flag = false
          deq_cond.signal
        ensure
          deq_mutex.unlock
        end

        [resource, ok]
      end

      def close
        deq_mutex.synchronize do
          self.close_flag = true
          enq_cond.broadcast
          deq_cond.broadcast
          notify
          self
        end
      end

      def closed?
        close_flag
      end

      alias_method :<<, :push
      alias_method :enq, :push
      alias_method :deq, :pop
      alias_method :shift, :pop

      private

      attr_accessor :enq_mutex, :deq_mutex, :enq_cond,
                    :deq_cond, :resource_array, :close_flag,
                    :have_enq_waiting_flag, :have_deq_waiting_flag
    end


    # BufferChan
    #
    #
    #
    #
    #
    #
    class BufferChan < SizedQueue
      include Chan
      include Enumerable

      def each
        if block_given?
          loop do
            begin
              yield pop(true)
            rescue ThreadError
              return
            end
          end
        else
          enum_for(:each)
        end
      end

      def initialize(max)
        super(max)
        self.io_r, self.io_w = IO.pipe
        @mutex               = Mutex.new
      end

      def push(obj, nonblock = false)
        super(obj, nonblock)
        notify
        self
      rescue ThreadError
        raise ClosedQueueError.new if closed?
        raise
      end

      def pop(nonblock = false)
        @mutex.synchronize do
          res = nil
          ok  = true
          ok  = false if empty? && closed?
          begin
            res = super(nonblock)
            notify
          rescue ThreadError
            raise unless closed?
            ok = false
          end
          [res, ok]
        end
      end

      def clear
        super
        notify
        self
      end

      def close
        @mutex.synchronize do
          super
          notify
          self
        end
      end

      alias_method :<<, :push
      alias_method :enq, :push
      alias_method :deq, :pop
      alias_method :shift, :pop
    end


    # select_chan
    #
    #
    #
    #
    #
    #
    #
    def select_chan(*ops)
      ops.shuffle!

      while true do
        ios = []
        ops.each do |op|
          ios << op.io
        end

        ops.each do |op|
          begin
            return op.call
          rescue ThreadError
          end
        end

        return yield if block_given?

        IO.select(ios)
      end

    end

    # on_read
    #
    #
    #
    #
    def on_read(chan:, &blk)
      raise ArgumentError.new('chan must be a Chan') unless chan.is_a? Chan
      op = Proc.new do
        res, ok = chan.deq(true)
        if blk.nil?
          [res, ok]
        else
          blk.call(res, ok)
        end
      end
      op.define_singleton_method(:io) do
        chan.send :io_r
      end
      op
    end

    # on_write
    #
    #
    #
    #
    #
    def on_write(chan:, obj:, &blk)
      raise ArgumentError.new('chan must be a Chan') unless chan.is_a? Chan
      op = Proc.new do
        res = chan.enq(obj, true)
        res = blk.call unless blk.nil?
        res
      end

      op.define_singleton_method(:io) do
        chan.send :io_r
      end
      op
    end

    module_function :select_chan, :on_read, :on_write
  end
end