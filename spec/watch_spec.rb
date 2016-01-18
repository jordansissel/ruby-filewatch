require 'filewatch/watch'
require 'stud/temporary'
require_relative 'spec_helper'
## A note about the sequence delay times.
#  because the file mtimes and close_older etc.
#  are never more granular than 1 second,
#  when delay times are floats the measured time
#  can be rounded up or down.
#  so try to use float delays closer to the best integer
#  where it matters

describe FileWatch::Watch do
  before(:all) do
    @thread_abort = Thread.abort_on_exception
    Thread.abort_on_exception = true
  end

  after(:all) do
    Thread.abort_on_exception = @thread_abort
  end

  let(:directory) { Stud::Temporary.directory }
  let(:watch_dir) { File.join(directory, "*.log") }
  let(:file_path) { File.join(directory, "1.log") }
  let(:loggr)     { double("loggr", :debug? => true) }
  let(:results)   { [] }
  let(:stat_interval) { 0.1 }
  let(:discover_interval) { 4 }

  let(:subscribe_proc) do
    lambda do
      formatted_puts("subscribing")
      subject.subscribe(stat_interval, discover_interval) do |event, watched_file|
        results.push([event, watched_file.path])
      end
    end
  end

  subject { FileWatch::Watch.new(:logger => loggr) }

  before do
    allow(loggr).to receive(:debug)
  end
  after do
    FileUtils.rm_rf(directory)
  end

  context "when watching a directory with files" do
    let(:actions) do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching when directory has files") do
          subject.watch(watch_dir)
        end
        .then_after(0.55, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial and one modify file events" do
      actions.activate
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path]])
    end
  end

  context "when watching a directory without files and one is added" do
    before do
      RSpec::Sequencing
        .run("start watching before any files are written") do
          subject.watch(watch_dir)
        end
        .then_after(0.25, "create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create and one modify file events" do
      subscribe_proc.call
      expect(results).to eq([[:create, file_path], [:modify, file_path]])
    end
  end

  context "when watching a directory with files and data is appended" do
    before do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching after file is written") do
          subject.watch(watch_dir)
        end
        .then_after(0.45, "append more lines to the file") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "yields create_initial and two modified file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:modify, file_path]])
    end
  end

  context "when unwatching a file and data is appended" do
    before do
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.25, "start watching after file is written") do
          subject.watch(watch_dir)
        end
        .then_after(0.25, "unwatch the file") do
          results.clear
          subject.unwatch(file_path)
        end
        .then_after(0.25, "append more lines to the file") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(0.45, "quit after a short time") do
          subject.quit
        end
    end

    it "does not yield events after unwatching" do
      subscribe_proc.call
      expect(results).to eq([])
    end
  end

  context "when close older expiry is enabled" do
    before do
      subject.close_older = 2
      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.45, "start watching before file ages more than close_older") do
          subject.watch(watch_dir)
        end
        .then_after(2.55, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, modify and timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when close older expiry is enabled and after timeout the file is appended-to" do
    before do
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then("start watching before file ages more than close_older") do
          subject.watch(watch_dir)
        end
        .then_after(3.1, "append more lines to file after file ages more than close_older") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(3.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, modify, timeout then modify, timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore older expiry is enabled and all files are already expired" do
    before do
      subject.ignore_older = 1

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(2, "start watching after file ages more than ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields no file events" do
      subscribe_proc.call
      expect(results).to eq([])
    end
  end

  context "when ignore_older is less than close_older and all files are not expired" do
    before do
      subject.ignore_older = 1
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(0.75, "start watching before file age reaches ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(2.45, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields create_initial, modify, timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end

  context "when ignore_older is less than close_older and all files are expired" do
    before do
      subject.ignore_older = 1
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(1.95, "start watching after file ages more than ignore_older") do
          subject.watch(watch_dir)
        end
        .then_after(1.25, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields no file events" do
      subscribe_proc.call
      expect(results).to eq([])
    end
  end

  context "when ignore older and close older expiry is enabled and after timeout the file is appended-to" do
    before do
      subject.ignore_older = 2
      subject.close_older = 2

      RSpec::Sequencing
        .run("create file") do
          File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
        end
        .then_after(3.1, "start watching after file ages more than ignore_older") do
          subject.watch(watch_dir)
        end
        .then("append more lines to file after file ages more than ignore_older") do
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
        .then_after(3.1, "quit after allowing time to close the file") do
          subject.quit
        end
    end

    it "yields unignore, modify then timeout file events" do
      subscribe_proc.call
      expect(results).to eq([[:unignore, file_path], [:modify, file_path], [:timeout, file_path]])
    end
  end
end
