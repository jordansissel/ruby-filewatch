require 'filewatch/watch'
require 'stud/temporary'

Thread.abort_on_exception = true

describe FileWatch::Watch do
  let(:directory) { Stud::Temporary.directory }
  let(:file_path) { File.join(directory, "1.log") }
  let(:loggr)     { double("loggr", :debug? => true) }
  let(:results)   { [] }
  let(:quit_proc) do
    lambda do
      Thread.new do
        sleep 1
        subject.quit
      end
    end
  end
  let(:subscribe_proc) do
    lambda do
      subject.subscribe(0.1, 4) do |event, path|
        results.push([event, path])
      end
    end
  end
  let(:log_simulation_proc) do
    lambda do
      Thread.new do
        File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
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
    it "yields create_initial and one modify file events" do
      th = log_simulation_proc.call
      th.join
      subject.watch(File.join(directory, "*"))
      quit_proc.call
      subscribe_proc.call
      expect(results).to eq([[:create_initial, file_path], [:modify, file_path]])
    end
  end

  context "when watching a directory without files and one is added" do
    it "yields create and one modify file events" do
      subject.watch(File.join(directory, "*"))

      th = log_simulation_proc.call
      th.join

      quit_proc.call
      subscribe_proc.call

      expect(results).to eq([[:create, file_path], [:modify, file_path]])
    end
  end

  context "when watching a directory with files and data is appended" do
    let(:log_simulation_next_proc) do
      lambda do
        Thread.new do
          sleep 0.5
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
      end
    end

    it "yields create_initial and two modified file events" do
      th = log_simulation_proc.call
      th.join # synchronous, wait WAIT for it, AAAAATENSHUN!

      subject.watch(File.join(directory, "*"))

      log_simulation_next_proc.call # asynchronous

      quit_proc.call
      subscribe_proc.call

      expect(results).to eq([[:create_initial, file_path], [:modify, file_path], [:modify, file_path]])
    end
  end

  context "when unwatching a file and data is appended" do
    let(:log_simulation_next_proc) do
      lambda do
        Thread.new do
          sleep 0.2
          results.clear
          subject.unwatch(file_path)
          sleep 0.2
          File.open(file_path, "ab") { |file|  file.write("line3\nline4\n") }
        end
      end
    end

    it "does not yield events after unwatching" do
      th = log_simulation_proc.call
      th.join # synchronous
      subject.watch(File.join(directory, "*"))

      log_simulation_next_proc.call # asynchronous

      quit_proc.call
      subscribe_proc.call

      expect(results).to eq([])
    end
  end

end
