require 'filewatch/watch'
require 'filewatch/watched_file'
require 'filewatch/watched_file_store'
require 'stud/temporary'
require_relative 'helpers/spec_helper'

describe FileWatch::WatchedFileStore do
  let(:path)  { FileWatch.path_to_fixture("ten_alpha_lines.txt") }
  let(:stat)  { File.stat(path) }
  let(:inode) { FileWatch::Watch.inode(path, stat) }
  let(:raw_inode) { inode.first }
  let(:position) { stat.size } # we read it all
  let(:directory) { Stud::Temporary.directory }
  let(:serial_obj) do
    FileWatch::WatchedFile.new_ongoing(path, inode, stat).tap do |o|
      o.update_bytes_read(position)
      # give it some state history
      o.activate
      o.close
    end
  end
  let(:watched_obj) { FileWatch::WatchedFile.new_ongoing(path, inode, stat) }
  let(:sincedb_path) { directory + "/store.sdb" }
  let(:loggr) { FileWatch::FileLogTracer.new }

  let(:store) do
    described_class.new(32, sincedb_path, loggr)
  end

  def persist_db()
    write_store = described_class.new(32, sincedb_path, loggr)
    write_store.upsert(serial_obj)
    write_store.close
    write_store = nil
    expect(File.stat(sincedb_path).size).not_to be_zero
  end

  def discover(filepath)
    st = File.stat(filepath)
    ino = FileWatch::Watch.inode(filepath, st)
    FileWatch::WatchedFile.new_ongoing(filepath, ino, st)
  end

  context "when using an empty db" do
    it "a watched file is upserted " do
      expect(store.find("path", path)).to be_empty
      store.upsert(watched_obj)
      expect(store.find("path", path)).to eq([watched_obj])
      expect(store.size).to eq(1)
    end
  end

  describe "loading the db from a legacy file" do
    before do
      str = "#{raw_inode} 0 0 #{position}"
      File.open(sincedb_path, "wb") { |file|  file.write("#{str}\n\n\n\n") }
    end

    context "and when the file is not modified" do
      it "a watched file is upserted, existing is removed" do
        expect(store.find("inode", inode)).not_to be_empty
        expect(watched_obj.bytes_read).to eq(0)

        store.upsert(watched_obj)

        found = store.find("path", path)
        expect(found).to eq([watched_obj])
        expect(watched_obj.bytes_read).to eq(position)
        expect(store.size).to eq(1)
      end
    end

    context "and when the file has grown" do
      let(:path) do
        (directory + "/bfile.log").tap do |fs|
          File.open(fs, "wb") { |file|  file.write("line1\nline2\n") }
        end
      end
      let(:position) { 12 } # we read the first two lines

      before do
        File.open(path, "ab") { |file|  file.write("line3\nline4\n") }
      end

      it "a watched file is upserted, existing is removed" do
        found1 = store.find("inode", inode).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)

        store.upsert(discover(path))

        found2 = store.find("inode", inode).first
        expect(found2).not_to eq(found1)
        expect(found2.bytes_read).to eq(position)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "and when the file has shrunk" do
      let(:path) do
        (directory + "/bfile.log").tap do |fs|
          File.open(fs, "wb") { |file|  file.write("line1\nline2\n") }
        end
      end
      let(:position) { 12 } # we read the first two lines

      before do
        File.open(path, "wb") { |file|  file.write("line3\n") }
      end

      it "a watched file is upserted, existing is removed" do
        found1 = store.find("inode", inode).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)

        store.upsert(discover(path))

        found2 = store.find("inode", inode).first
        expect(found2).not_to eq(found1)
        expect(found2.bytes_read).to eq(0)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "and when the file is very different but using the same inode" do
      let(:path) do
        (directory + "/afile.log").tap do |fs|
          File.open(fs, "wb") { |file|  file.write("lineA\nlineB\nlineC\nlineD\n") }
        end
      end
      let(:bpath)  { directory + "/bfile.log" }
      let(:position) { 12 } # we read the first two lines

      it "a watched file is upserted, BUG: we will not read the first 12 bytes! we just can't tell that it has different content" do
        found1 = store.find("inode", inode).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)

        FileUtils.mv(path, bpath)
        File.open(bpath, "wb") { |file|  file.write("line3\nline4\n" * 50) }

        store.upsert(discover(bpath))

        found2 = store.find("inode", inode).first
        expect(found2).not_to eq(found1)
        expect(found2.bytes_read).to eq(12)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end
  end

  describe "loading the db from a WatchedFileStore file" do
    context "when seeing the same file a second time" do
      before do
        persist_db
      end

      it "the discovered file is ignored and the read file is used" do
        found1 = store.find("path", path).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)

        store.upsert(discover(path))

        found2 = store.find("path", path).first
        expect(found2).to eq(found1)
        expect(found2.bytes_read).to eq(position)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "when the file has more content than was last saved" do
      let(:path)  { directory + "/afile.log" }
      let(:position) { 12 } # we read the first two lines
      before do
        File.open(path, "wb") { |file|  file.write("line1\nline2\n") }
        persist_db
        File.open(path, "ab") { |file|  file.write("line3\nline4\n") }
      end

      it "a discovered file is ignored and the read file is used" do
        found1 = store.find("path", path).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)

        store.upsert(discover(path))

        found2 = store.find("path", path).first
        expect(found2).to eq(found1)
        expect(found2.bytes_read).to eq(position)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "when a file path is used for a different file" do
      let(:path)  { directory + "/cfile.log" }
      let(:position) { 12 } # we read the first two lines
      before do
        File.open(path, "wb") { |file| file.write("line1\nline2\n") }
        persist_db
        FileUtils.rm(path)
        File.open(path, "wb") { |file| file.write("LINE-AAAA\nLINE-BBBB\n") }
      end

      it "a discovered file is used and the read file removed, read_bytes == 0" do
        found1 = store.find("path", path).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)

        store.upsert(discover(path))

        found2 = store.find("path", path).first
        expect(found2).not_to eq(found1)
        expect(found2.bytes_read).to eq(0)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "when a file is renamed after its sincedb record was written" do
      let(:path)  { directory + "/cfile.log" }
      let(:bpath) { directory + "/bfile.log" }
      let(:position) { 6 * 4000 } # we read 4 thousand lines
      before do
        File.open(path, "wb") { |file| file.write("line1\nline2\n" * 5000) }
        persist_db
      end

      it "a discovered file is ignored and the read file used, read_bytes == 24000" do
        found1 = store.find("path", path).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)
        FileUtils.mv(path, bpath)

        store.upsert(discover(bpath))

        found2 = store.find("path", bpath).first
        # path was updated, i.e. found1 was found again
        expect(found2).to eq(found1)
        expect(found2.bytes_read).to eq(24000)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "when a file is renamed and truncated after its sincedb record was written" do
      let(:path)  { directory + "/cfile.log" }
      let(:bpath) { directory + "/bfile.log" }
      let(:position) { 6 * 4000 } # we read 4 thousand lines
      before do
        File.open(path, "wb") { |file| file.write("line1\nline2\n" * 5000) }
        persist_db
      end

      it "a discovered file is used and the read file removed, read_bytes == 0" do
        found1 = store.find("path", path).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)
        FileUtils.mv(path, bpath)
        File.open(bpath, "wb") { |file|  file.write("") }

        store.upsert(discover(bpath))

        found2 = store.find("path", bpath).first
        expect(found2).not_to eq(found1)
        expect(found2.bytes_read).to eq(0)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end

    context "when a file is renamed and appended to after its sincedb record was written" do
      let(:path)  { directory + "/cfile.log" }
      let(:bpath) { directory + "/bfile.log" }
      let(:position) { 6 * 4000 } # we read 4 thousand lines
      before do
        File.open(path, "wb") { |file| file.write("line1\nline2\n" * 5000) }
        persist_db
      end

      it "a discovered file is ignored and the read file used, read_bytes == 24000" do
        found1 = store.find("path", path).first
        expect(found1).not_to be_nil
        expect(found1.filestat).to be_a(FileWatch::WatchedFile::FakeStat)
        FileUtils.mv(path, bpath)
        File.open(bpath, "ab") { |file| file.write("line3\nline4\n" * 50) }

        store.upsert(discover(bpath))

        found2 = store.find("path", bpath).first
        expect(found2).to eq(found1)
        expect(found2.bytes_read).to eq(24000)
        expect(found2.filestat).to be_a(File::Stat)
        expect(store.size).to eq(1)
      end
    end
  end
end
