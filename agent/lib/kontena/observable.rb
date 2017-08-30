module Kontena
  # The value does not yet exist when initialized, it is nil.
  # Once the value is first updated, then other Actors will be able to observe it.
  # When the value later updated, observing Actors will be notified of those changes.
  #
  # @attr observers [Hash{Kontena::Observer => Boolean}] stored value is the persistent? flag
  class Observable
    require_relative './observable/registry'

    # @return [Celluloid::Proxy::Cell<Kontena::Observable::Registry>] system registry actor
    def self.registry
      Celluloid::Actor[:observable_registry] || fail(Celluloid::DeadActorError, "Observable registry actor not running")
    end

    include Kontena::Logging

    attr_reader :logging_prefix # customize Kontena::Logging#logging_prefix by instance

    class Message
      attr_reader :observer, :observable, :value

      # @param observer [Kontena::Observer]
      # @param observable [Kontena::Observable]
      # @param value [Object, nil, Exception]
      def initialize(observer, observable, value)
        @observer = observer
        @observable = observable
        @value = value
      end
    end

    # mixin for Celluloid actor classes
    module Helper
      # Create a new Observable using the including class name as the subject.
      # Register the Observable with the Kontena::Observable::Registry.
      # Links to the registry to crash the Observable if the owning actor crashes.
      #
      # @return [Kontena::Observable]
      def observable
        @observable ||= Kontena::Observable.new(self.class.name).tap do |observable|
          observable_registry = Kontena::Observable.registry
          observable_registry.register(observable, self.current_actor)

          self.links << observable_registry # registry monitors owner
        end
      end
    end

    # @param subject [Object] used to identify the Observable for logging purposes
    def initialize(subject = nil)
      @subject = subject
      @mutex = Thread::Mutex.new
      @observers = {}
      @value = nil

      # include the subject (owning actor class, other resource) in log messages
      @logging_prefix = "#{self}"
    end

    # @return [String]
    def to_s
      "#{self.class.name}<#{@subject}>"
    end

    # @return [Object, nil] last updated value, or nil if not observable?
    def get
      @value
    end

    # Observable has updated, and has not reset
    #
    # @return [Boolean]
    def observable?
      !!@value
    end

    def crashed?
      Exception === @value
    end

    # Observable has observers
    #
    # @return [Boolean]
    def observed?
      !@observers.empty?
    end

    # The Observable has a value. Propagate it to any observing Actors.
    #
    # This will notify any Observers, causing them to yield if ready.
    #
    # The value must be safe for access by multiple threads, even after this update,
    # and even after any later updates.
    #
    # TODO: automatically freeze the value?
    #
    # @param value [Object]
    # @raise [ArgumentError] Update with nil value
    def update(value)
      raise RuntimeError, "Observable crashed: #{@value}" if crashed?
      raise ArgumentError, "Update with nil value" if value.nil?

      debug { "update: #{value}" }

      set_and_notify(value)
    end

    # Reset the observable value back into the initialized stte.
    # This will notify any Observers, causing them to block until we update again.
    def reset
      debug { "reset" }

      set_and_notify(nil)
    end

    # @param reason [Exception]
    def crash(reason)
      raise ArgumentError, "Crash with non-exception: #{reason.class.name}" unless Exception === reason

      debug { "crash: #{reason}" }

      set_and_notify(reason)
    end

    # Observer is observing this Actor's @observable_value.
    # Subscribes observer for updates to our observable value, sending Kontena::Observable::Message to observing mailbox.
    # Returns Kontena::Observable::Message with current value.
    # The observer will be unsubscribed/unlinked once no longer alive?.
    #
    # @param observer [Kontena::Observer]
    # @param persistent [Boolean] always subscribe for future updates, otherwise only if no immediate value
    # @raise [Exception]
    # @return [Object] current value
    def add_observer(observer, persistent: true)
      @mutex.synchronize do
        if !@value
          # subscribe for future udpates, no value to return
          @observers[observer] = persistent

        elsif Exception === @value
          # raise with immediate value, no future updates to subscribe to
          raise @value

        elsif persistent
          # return with immediate value, also subscribe for future updates
          @observers[observer] = persistent

        else
          # return with immediate value, do not subscribe for future updates
        end

        return @value
      end
    end

    # Send @value to each Kontena::Observer
    #
    # @param value [Object, nil, Exception]
    def set_and_notify(value)
      @mutex.synchronize do
        @value = value

        @observers.each do |observer, persistent|
          if !observer.alive?
            debug { "dead: #{observer}" }

            @observers.delete(observer)

          elsif !persistent
            debug { "notify and drop: #{observer} <- #{value}" }

            observer << Message.new(observer, self, value)

            @observers.delete(observer)

          else
            debug { "notify: #{observer} <- #{value}" }

            observer << Message.new(observer, self, value)
          end
        end
      end
    end
  end
end
