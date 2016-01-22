#
# Copyright 2011-2013, Dell
# Copyright 2013-2015, SUSE LINUX GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "find"

class Backup < ActiveRecord::Base
  attr_accessor :file

  before_validation :save_or_create_archive, on: :create
  after_validation :delete_archive, unless: -> { errors.empty? }
  after_destroy :delete_archive

  validates :name,
    presence: true,
    uniqueness: true,
    format: {
      with: /\A[a-zA-Z0-9\-_]+\z/,
      message: "allows only letters and numbers"
    }
  validates :version,
    presence: true
  validates :size,
    presence: true

  validate :validate_chef_file_extension,
    :validate_version,
    :validate_hostname,
    :validate_upload_file_extension

  def path
    self.class.image_dir.join(filename)
  end

  def filename
    "#{name}.tar.gz"
  end

  def extract
    backup_dir = Dir.mktmpdir
    Archive.extract(path.to_s, backup_dir)
    Pathname.new(backup_dir)
  end

  def data
    @data ||= extract
  end

  def restore
    upgrade if upgrade?
    Crowbar::Backup::Restore.new(self).restore
  end

  def upgrade?
    ENV["CROWBAR_VERSION"].to_f > version
  end

  def upgrade
    upgrade = Crowbar::Upgrade.new(self)
    if upgrade.supported?
      upgrade.upgrade
    else
      errors.add(:base, I18n.t("backups.index.upgrade_not_supported"))
      return false
    end
  end

  class << self
    def image_dir
      if Rails.env.production?
        Pathname.new("/var/lib/crowbar/backup")
      else
        Rails.root.join("storage")
      end
    end
  end

  protected

  def save_or_create_archive
    if name.blank?
      save_archive
    else
      create_archive
    end
  end

  def create_archive
    dir = Dir.mktmpdir

    Crowbar::Backup::Export.new(dir).export
    Dir.chdir(dir) do
      ar = Archive::Compress.new(
        path.to_s,
        type: :tar,
        compression: :gzip
      )
      ar.compress(::Find.find(".").select { |f| f.gsub!(/^.\//, "") if ::File.file?(f) })
    end
    self.version = ENV["CROWBAR_VERSION"]
    self.size = path.size
  ensure
    FileUtils.rm_rf(dir)
  end

  def save_archive
    self.name = file.original_filename.remove(".tar.gz")

    if path.exist?
      errors.add(:filename, I18n.t(".invalid_filename_exists", scope: "backups.index"))
      return false
    end

    path.open("wb") do |f|
      f.write(file.read)
    end

    meta = YAML.load_file(data.join("meta.yml"))
    self.version = meta["version"]
    self.size = path.size
    self.created_at = Time.zone.parse(meta["created_at"])
  end

  def delete_archive
    path.delete if path.exist?
  end

  def validate_chef_file_extension
    Dir.glob(data.join("knife", "**", "*")).each do |file|
      next if Pathname.new(file).directory?
      next if File.extname(file) == ".json"
      errors.add(:base, I18n.t("backups.validation.non_json_file"))
    end
  end

  def validate_version
    if version < 1.9
      errors.add(:base, I18n.t("backups.validation.version_too_low"))
    elsif version > ENV["CROWBAR_VERSION"].to_f
      errors.add(:base, I18n.t("backups.validation.version_too_high"))
    end
  end

  def validate_hostname
    backup_hostname = data.join("crowbar", "configs", "hostname").read.strip
    system_hostname = `hostname -f`.strip

    unless system_hostname == backup_hostname
      errors.add(:base, I18n.t("backups.validation.hostnames_not_identical"))
    end
  end

  def validate_upload_file_extension
    return if !file || (file && file.original_filename.match(/tar\.gz$/))

    errors.add(:base, I18n.t("backups.validation.invalid_file_extension"))
  end
end