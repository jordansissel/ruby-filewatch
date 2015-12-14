require 'filewatch/tail'
require 'stud/temporary'
require "rbconfig"

describe FileWatch::Tail do
  before(:all) do
    @thread_abort = Thread.abort_on_exception
    Thread.abort_on_exception = true
  end

  after(:all) do
    Thread.abort_on_exception = @thread_abort
  end

  let(:file_path) { f = Stud::Temporary.pathname }
  let(:sincedb_path) { Stud::Temporary.pathname }
  let(:quit_sleep) { 0.5 }

  before :each do
    Thread.new(subject) { sleep quit_sleep; subject.quit } # force the subscribe loop to exit
  end

  after :each do
    FileUtils.rm_rf(file_path)
    FileUtils.rm_rf(sincedb_path)
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

    before :each do
      File.open(file_path, "wb") { |file|  file.write("line1\nline2\n") }
      subject.tail(file_path)
    end

    context "when reading a new file" do
      it "updates sincedb after subscribe" do
        subject.subscribe {|_,_|  }
        stat = File::Stat.new(file_path)
        sincedb_id = subject.sincedb_record_uid(file_path,stat).join(' ')
        expect(File.read(sincedb_path)).to eq("#{sincedb_id} #{stat.size}\n")
      end
    end

    context "when restarting tail" do
      before :each do
        subject.subscribe {|_,_| }
        sleep quit_sleep + 0.1 # wait for tail.quit
        subject.tail(file_path) # re-tail file
        File.open(file_path, "ab") { |file| file.write("line3\nline4\n") }
        Thread.new(subject) { sleep 0.5; subject.quit }
      end

      it "picks off from where it stopped" do
        expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line3"], [file_path, "line4"])
      end

      it "updates on tail.quit" do
        subject.subscribe {|_,_| }
        stat = File::Stat.new(file_path)
        sincedb_id = subject.sincedb_record_uid(file_path,stat).join(' ')
        expect(File.read(sincedb_path)).to eq("#{sincedb_id} #{stat.size}\n")
      end
    end
  end

  context "ingesting files bigger than 32k" do
    let(:lineA) { "a" * 12000 }
    let(:lineB) { "b" * 25000 }
    let(:lineC) { "c" * 8000 }
    subject { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning) }

    before :each do
      IO.write(file_path, "#{lineA}\n#{lineB}\n#{lineC}\n")
    end

    context "when restarting after stopping at the first line" do

      let(:new_subject) { FileWatch::Tail.new(:sincedb_path => sincedb_path, :start_new_files_at => :beginning) }

      before :each do
        subject.tail(file_path)
        subject.subscribe {|f, l| break if @test; @test = 1}
        subject.sincedb_write
        subject.quit
        Thread.new(new_subject) { sleep 0.5; new_subject.quit } # force the subscribe loop to exit
      end

      it "should store in sincedb the position up until the first string" do
        device, dev_major, dev_minor, pos = *IO.read(sincedb_path).split(" ").map {|n| n.to_i }
        expect(pos).to eq(12001) # string.bytesize + "\n".bytesize
      end

      it "should read the second and third lines entirely" do
        new_subject.tail(file_path) # re-tail file
        expect { |b| new_subject.subscribe(&b) }.to yield_successive_args([file_path, lineB], [file_path, lineC])
      end
    end
  end

  context "when watching a directory" do

    let(:directory) { Stud::Temporary.directory }
    let(:file_path) { File.join(directory, "1.log") }

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
        Thread.new(subject) { |s| sleep 1; s.quit }
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
  end
end
