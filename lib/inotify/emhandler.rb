require "inotify/fd"
require "inotify/namespace"

class Inotify::EMHandler < EventMachine::Connection
  def initialize(inotify_fd, callback=nil)
    @inotify = inotify_fd
    @callback = callback
    self.notify_readable = true
  end

  def notify_readable
    @inotify.each do |event|
      @callback.call(event)
    end
  end
end
