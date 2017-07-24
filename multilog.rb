
require 'logger'

class MultiDelegator
  def initialize(*targets)
    @targets = targets
  end

  def self.delegate(*methods)
    methods.each do |m|
      define_method(m) do |*args|
        @targets.map { |t| t.send(m, *args) }
      end
    end
    self
  end

  class <<self
    alias to new
  end
end

log_file = File.open("debug.log", "a")
log = Logger.new(MultiDelegator.delegate(:write, :close).to(STDOUT, log_file))
log.datetime_format = '%Y-%m-%d %H:%M:%S'
log.formatter = proc do |severity, datetime, progname, msg|
  next "#{datetime}: #{msg}\n"
end
log.warn("test")

