require "io/event"
require "timers"
require "resolv"

module Kernel
  def FiberScheduler
    scheduler = ::FiberScheduler.new
    Fiber.set_scheduler(scheduler)
    yield

    scheduler.run
  ensure
    Fiber.set_scheduler(nil)
  end
end

class FiberScheduler
  TimeoutError = Class.new(RuntimeError)

  def initialize
    @timers = Timers::Group.new
    @selector = IO::Event::Selector.new(Fiber.current)

    @blocked = 0
    @count = 0
  end

  def run
    while @blocked > 0
      interval = @timers.wait_interval

      if interval && interval < 0
        # We have timers ready to fire, don't sleep in the selctor:
        interval = 0
      end

      @selector.select(interval)

      @timers.fire
    end
  end

  # Fiber::SchedulerInterface methods below

  def close
    run

    raise("Closing scheduler with blocked operations!") if @blocked > 0

    # We depend on GVL for consistency:
    @selector&.close
    @selector = nil
  end

  def block(blocker, timeout)
    if timeout
      fiber = Fiber.current
      timer = @timers.after(timeout) do
        if fiber.alive?
          fiber.transfer(false)
        end
      end
    end

    begin
      @blocked += 1
      @selector.transfer
    ensure
      @blocked -= 1
    end
  ensure
    timer&.cancel
  end

  def unblock(blocker, fiber)
    @selector.push(fiber)
  end

  def kernel_sleep(duration = nil)
    if duration
      block(nil, duration)
    else
      @selector.transfer
    end
  end

  def address_resolve(hostname)
    @blocked += 1
    Resolv.getaddresses(hostname)
  ensure
    @blocked -= 1
  end

  def io_wait(io, events, timeout = nil)
    fiber = Fiber.current
    if timeout
      timer = @timers.after(timeout) do
        fiber.raise(TimeoutError)
      end
    end

    events =
      begin
        @blocked += 1
        @selector.io_wait(fiber, io, events)
      ensure
        @blocked -= 1
      end

    return events
  rescue TimeoutError
    return false
  ensure
    timer&.cancel
  end

  def io_read(io, buffer, length)
    @blocked += 1
    @selector.io_read(Fiber.current, io, buffer, length)
  ensure
    @blocked -= 1
  end

  def io_write(io, buffer, length)
    @selector.io_write(Fiber.current, io, buffer, length)
  end

  def process_wait(pid, flags)
    @blocked += 1
    @selector.process_wait(Fiber.current, pid, flags)
  ensure
    @blocked -= 1
  end

  def timeout_after(timeout, exception = TimeoutError, message = "execution expired", &block)
    fiber = Fiber.current
    timer = @timers.after(timeout) do
      if fiber.alive?
        fiber.raise(exception, message)
      end
    end

    @blocked += 1
    yield timeout
  ensure
    timer.cancel if timer
    @blocked -= 1
  end

  def fiber(&block)
    fiber = Fiber.new(blocking: false, &block)
    @count += 1
    fiber.tap(&:transfer)
  ensure
    @count -= 1
  end
end
