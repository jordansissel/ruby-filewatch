require 'filewatch/tail'
require 'stud/temporary'

describe FileWatch::Tail do

  let(:file_path) { f = Stud::Temporary.pathname }
  let(:sincedb_path) { Stud::Temporary.pathname }

  before :each do
    Thread.new(subject) { sleep 0.5; subject.quit } # force the subscribe loop to exit
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

    context "when file is deleted" do
      # retrieve the file inode before it is deleted
      let!(:sincedb_id) { subject.sincedb_record_uid(file_path,File::Stat.new(file_path)) }

      before :each do
        File.open(file_path, "ab") { |file|  file.write("line3\n") }
        Thread.new(subject) { sleep 0.2; File.unlink(file_path) }
      end

      it "remove related record from in-memory sincedb" do
        expect { |b| subject.subscribe(&b) }.to yield_successive_args([file_path, "line1"], [file_path, "line2"],[file_path, "line3"])
        #rspec var scoping requires this
        local_sincedb_id = sincedb_id
        expect(subject.instance_eval { @sincedb.member?(local_sincedb_id)}).to eq(false)
      end
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
        sleep 0.6 # wait for tail.quit
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
end

