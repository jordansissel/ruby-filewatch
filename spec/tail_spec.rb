
__END__

require_relative 'helpers/spec_helper'

describe "FileWatch::Tail (yielding)" do
  before(:all) do
    @thread_abort = Thread.abort_on_exception
    Thread.abort_on_exception = true
  end

  after(:all) do
    Thread.abort_on_exception = @thread_abort
  end

  let(:directory) { Stud::Temporary.directory }
  let(:dir_sdb) { Stud::Temporary.directory }
  let(:file_path) { File.join(directory, "1.log") }
  let(:sincedb_path) { File.join(dir_sdb, "sincedb.log") }
  let(:quit_sleep) { 0.5 }
  let(:quit_proc) { lambda { subject.quit } }
  let(:sincedb_version) { "v1" }

  before :each do
    FileUtils.rm_rf(sincedb_path)
    Thread.new(subject) { sleep quit_sleep; quit_proc.call } # force the subscribe loop to exit
  end

  after :each do
    FileUtils.rm_rf(directory)
    FileUtils.rm_rf(dir_sdb)
  end

  context "when watching a new file" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    before :each do
      subject.tail(file_path)
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
    end

    it "reads new lines off the file" do
      expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
    end
  end

  context "when watching a file" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.tail(file_path)
    end

    it "reads new lines off the file" do
      expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
    end

  end

  context "when watching a CRLF file" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path,
                                  :start_new_files_at => :beginning,
                                  :delimiter => "\r\n") }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("line1\r\nline2\r\n") }
      subject.tail(file_path)
    end

    it "reads new lines off the file" do
      expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
    end
  end

  context "when a file is deleted" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning) }

    before :each do
      File.open(file_path, "w") { |file|  file.write("line1\nline2\n") }
      subject.tail(file_path)
      File.unlink file_path
    end

    it "should not raise exception" do
      Thread.new(subject) { sleep 0.1; subject.quit } # force the subscribe loop to exit
      expect { subject.subscribe {|p,l| } }.to_not raise_exception
    end
  end

  describe "sincedb" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }
    let(:quit_proc) { lambda {  } }

    context "when reading a new file" do
      it "updates sincedb after subscribe" do
        RSpec::Sequencing
          .run("create file") do
            File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
          end
          .then("begin tailing") do
            subject.tail(file_path)
          end
          .then_after(quit_sleep, "quit tailing") do
            subject.quit
          end
        subject.subscribe {|_,_|  }
        expect(File.read(sincedb_path)).to eq("#{FileWatch.sincedb_record(sincedb_version, file_path)}\n")
      end
    end

    context "when restarting tail" do
      let(:restart_actions) do
        RSpec::Sequencing
          .run("create file") do
            File.open(file_path, "w") { |file|  file.write("line1\nline2\n") }
            stats << File::Stat.new(file_path)
          end
          .then("begin tailing") do
            subject.tail(file_path)
          end
          .then_after(quit_sleep, "quit tailing") do
            subject.quit
          end
          .then_after(0.45, "begin tailing again") do
            results << File.read(sincedb_path).chomp
            subject.tail(file_path)
          end
          .then_after(0.45, "write more lines to the file") do
            File.open(file_path, "a") { |file| file.write("line3\nline4\n") }
            stats << File::Stat.new(file_path)
          end
          .then_after(2.1, "quit tailing") do
            subject.quit
          end
          .then_after(0.25, "read sincedb file") do
            results << File.read(sincedb_path).chomp
          end
      end

      let(:results) { [] }
      let(:stats)   { [] }

      it "picks off from where it stopped" do
        restart_actions.activate
        subject.subscribe {|_,_| }
        expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line3"], [file_path, "line4"])
      end

      it "updates on tail.quit" do
        restart_actions.activate
        subject.subscribe {|_,_| }
        subject.subscribe {|_,_| }
        restart_actions.value
        expect(results.first).to eq("#{FileWatch.sincedb_record(sincedb_version, file_path, stats.first.size)}\n")
        expect(results.last).to eq("#{FileWatch.sincedb_record(sincedb_version, file_path, stats.last.size)}\n")
      end
    end
  end

  context "ingesting files bigger than 32k" do
    let(:lineA) { "a" * 12000 }
    let(:lineB) { "b" * 25000 }
    let(:lineC) { "c" * 8000 }
    let(:flags) { [false] }
    let(:opts)  { {:sincedb_path => sincedb_path, :start_new_files_at => :beginning} }
    let(:new_subject) { FileWatch::Tail.new(opts) }
    let(:quit_proc) { lambda {  } }
    before do
      IO.write(file_path, "#{lineA}\n#{lineB}\n#{lineC}\n")
      subject.tail(file_path)
      subject.subscribe {|f, l| break if flags[0]; flags.unshift(true)}
      subject.sincedb_write
      subject.quit
    end

    subject { FileWatch::Tail.new(opts) }

    context "when restarting after stopping at the first line" do
      it "should store in sincedb the position up until the first string" do
        pos = FileWatch.extract_pos(IO.read(sincedb_path))
        expect(pos.to_i).to eq(lineA.bytesize + "\n".bytesize)
      end

      it "should read the second and third lines entirely" do
        RSpec::Sequencing
          .run_after(0.25, "quit new_subject") do
            new_subject.quit
          end
        new_subject.tail(file_path) # re-tail file
        expect { |b| new_subject.subscribe(&b) }.to yield_successive_args([file_path, lineB], [file_path, lineC])
      end
    end
  end

  context "when watching a directory" do
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

    before :each do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.tail(File.join(directory, "*"))
    end

    after :each do
      FileUtils.rm_rf(directory)
    end

    it "reads new lines from the beginning" do
      expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
    end

    context "when a file is renamed" do
      before :each do
        expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"])
        File.rename(file_path, file_path + ".bak")
      end

      it "should not re-read the file" do
        RSpec::Sequencing.run_after(1.0, "quit") { subject.quit }
        expect { |b| subject.subscribe(&b) }.not_to yield_control
      end
    end

    let(:new_file_path) { File.join(directory, "2.log") }

    context "when a new file is later added to the directory" do
      # Note tests in this context rely on FileWatch::Watch reading
      # file 1.log first then 2.log and that depends on how Dir.glob is implemented
      # in different rubies on different operating systems
      before do
        File.open(new_file_path, "wb") { |file|  file.write("line2.1\nline2.2\n") }
      end

      it "reads new lines from the beginning for all files" do
        expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"],
                                                                        [new_file_path, "line2.1"], [new_file_path, "line2.2"])
      end

      context "and when the sincedb path is not given" do
        subject { FileWatch::Tail.new(:start_new_files_at => :beginning, :stat_interval => 0) }

        it "reads new lines from the beginning for all files" do
          expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"],
                                                                        [new_file_path, "line2.1"], [new_file_path, "line2.2"])
        end
      end
    end
  end

  if RbConfig::CONFIG['host_os'] !~ /mswin|mingw|cygwin/
    context "when quiting" do
      subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning, :stat_interval => 0) }

      before :each do
        subject.tail(file_path)
        File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      end

      it "closes the file handles" do
        buffer = []
        subject.subscribe do |path, line|
          buffer.push([path, line])
        end
        lsof = `lsof -p #{Process.pid} | grep #{file_path}`
        expect(lsof).to be_empty
      end
    end

    context "when close_older is set" do
      let(:lsof_before_quit) { [] }
      let(:quit_proc) { FileWatch::NullCallable }

      subject do
        FileWatch::Tail.new(
          :sincedb_path => sincedb_path,
          :start_new_files_at => :beginning,
          :stat_interval => 0.1,
          :close_older => 1)
      end

      it "closes the file handles" do
        RSpec::Sequencing
          .run("begin tailing then create file") do
            subject.tail(file_path)
            File.open(file_path, "wb") { |file| file.write("line1\nline2\n") }
          end
          .then_after(1.95, "allow time to have files closed then quit") do
            lsof_before_quit.push `lsof -p #{Process.pid} | grep #{file_path}`
            subject.quit
          end
        buffer = []
        subject.subscribe do |path, line|
          if buffer.size.zero?
            lsof = `lsof -p #{Process.pid} | grep #{file_path}`
            # expect that the file is open
            expect(lsof).not_to be_empty
          end
          buffer.push([path, line])
        end
        # expect that the file is closed before quit closes it
        expect(lsof_before_quit.first).to be_empty
        expect(buffer).to eq([[file_path, "line1"], [file_path, "line2"]])
      end
    end
  end
end
