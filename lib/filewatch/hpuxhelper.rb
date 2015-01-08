require "ffi"
  
module Winhelper
  extend FFI::Library
  ffi_lib FFI::Library::LIBC
  
  # définition de type FileTime
  class FileTime < FFI::Struct
    layout :lowDateTime, :uint,
    :highDateTime, :uint
  end
  
  # définition de type FileInformation
  class FileInformation < FFI::Struct
    def initialize()
      createTime = FileTime.new
      lastAccessTime = FileTime.new
      lastWriteTime = FileTime.new
    end
    
    layout :fileAttributes, :uint, #DWORD    dwFileAttributes;
    :createTime, FileTime,  #FILETIME ftCreationTime;
    :lastAccessTime, FileTime, #FILETIME ftLastAccessTime;
    :lastWriteTime, FileTime, #FILETIME ftLastWriteTime;
    :volumeSerialNumber, :uint, #DWORD    dwVolumeSerialNumber;
    :fileSizeHigh, :uint, #DWORD    nFileSizeHigh;
    :fileSizeLow, :uint, #DWORD    nFileSizeLow;
    :numberOfLinks, :uint, #DWORD    nNumberOfLinks;
    :fileIndexHigh, :uint, #DWORD    nFileIndexHigh;
    :fileIndexLow, :uint #DWORD    nFileIndexLow;
  end
    
  
  attach_function :GetOpenFileHandle, :CreateFileA, [:pointer, :uint, :uint, :pointer, :uint, :uint, :pointer], :pointer  
  
  attach_function :GetFileInformationByHandle, [:pointer, :pointer], :int
  
  attach_function :CloseHandle, [:pointer], :int
  
  
  def self.GetHpUxUniqueFileIdentifier(path)
    handle = GetOpenFileHandle(path, 0, 7, nil, 3, 128, nil)
    fileInfo = Winhelper::FileInformation.new
    success = GetFileInformationByHandle(handle, fileInfo)
    CloseHandle(handle)
    if  success == 1
      return "#{fileInfo[:volumeSerialNumber]}-#{fileInfo[:fileIndexLow]}-#{fileInfo[:fileIndexHigh]}"
    else
      #p "cannot retrieve file information, returning path"
      return path;
    end
  end
end

