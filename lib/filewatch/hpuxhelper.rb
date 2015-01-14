module Hpuxhelper

    def self.GetHpuxFileInode(path)
        hpuxfileino = ""
        IO.popen("ls -i #{path} | awk '{print $1}'").each do |line|
          hpuxfileino = line.chomp
        end
        return hpuxfileino
    end

    def self.GetHpuxFileFilesystemMountPoint(path)
        hpuxfsname = ""
        IO.popen("df -n #{path} | awk '{print $1}'").each do |line|
          hpuxfsname = line.chomp
        end
        return hpuxfsname
    end
end