require "filewatch/inotify/fd"
require "filewatch/namespace"

class FileWatch::Inotify::EMHandler < EventMachine::Connection
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
