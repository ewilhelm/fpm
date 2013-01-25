require "fpm/package"
require "json"
require "find"

# Premise: Sidestep all of the historical accidents and just require
# that we have a MYMETA.json v2+ -- for now, just start from there and
# add the download+make+(test?) business later (or not.)

class FPM::Package::CPAN < FPM::Package

  def input(package)
    path = package # TODO later: download + make
    raise "is not a directory" unless File.directory?(path)

    mymetajson = File.join(path, 'MYMETA.json')
    raise "must have MYMETA.json file #{metajson}" unless
      File.exists?(mymetajson)

    load_package_info(mymetajson)

    install_to_staging(path)
  end

  def load_package_info(mymetajson)
    i = JSON::parse(File.open(mymetajson).readlines.join(''))

    raise "must have modern meta-spec" unless i['meta-spec'] &&
      (i['meta-spec']['version'].to_f >= 2)

    # arch check for bs files (beats searching for so/dylib/dll/...)
    found_bs = 0
    archdir = File.expand_path('../blib/arch/auto', mymetajson)
    if File.exists?(archdir)
      ::Find.find(archdir) {|p|
        if p =~ /\.bs$/
          found_bs += 1
          Find.prune
        end
      }
    end
    self.architecture = found_bs > 0 ? 'native' : 'all'

    # TODO 'fix' package names:
    # debian = 'lib' + i['name'].downcase + '-perl' # XXX except libwww
    # redhat = 'perl-' + i['name']
    self.name        = i['name'].downcase
    self.version     = i['version'].sub(/^v/, '')
    self.license     = i['license'].join(',')
    self.description = i['abstract']
    self.vendor      = i['author'].join(',')
    self.url         = (i['resources']||{})['homepage']

    # TODO +recommends?
    deps = ((i['prereqs']||{})['runtime']||{})['requires']||{}
    depmap = packages_to_dists(deps.keys)
    self.dependencies += deps.map {|k,v|
      # TODO 'fix' dep names accordingly
      dist = depmap[k] or raise "no dist for dep #{k}!"
      next if dist == 'perl'
      v.split(/,\s+/).map {|req| "#{dist} #{req}"}
    }.flatten

  end

  def install_to_staging(path)
    # XXX the installbase or such is assumed to have been correct here
    ::Dir.chdir(path) {
      run = File.exists?('Build') ?
          ['./Build', 'install', '--destdir', staging_path]
        : File.exists?('Makefile') ?
          ['make', 'install', 'DESTDIR=' + staging_path]
        : (raise "no build / make artifacts found")
      safesystem(*run);

      # TODO just Find.find the perllocal.pod files?
      ::Dir.glob(staging_path + '/usr/lib/perl/*/perllocal.pod').each {|f|
        ::File.unlink(f)
      }
    }
  end

  def packages_to_dists (packages, details_file=nil)
    details_file ||=
      ::Dir.glob(ENV['HOME'] + '/.cpanm/sources/*/02packages.details.txt').
        sort {|a,b| b.stat.mtime <=> a.stat.mtime} [0]

    fh = File.open(details_file)
    fh.each_line {|line| break if line == "\n"}
    seeking = Hash[packages.map {|p| [p,true]}]
    got = {}
    fh.each_line {|line|
      (p, v, f) = line.chomp.split(/\s+/, 3)
      f or next
      seeking.delete(p) or next
      got[p] = f.match(%r{.*/(.*?)-[^-]+$})[1]
      seeking.keys.length > 0 or break
    }
    warn "could not locate dists for #{seeking.keys.join(',')}" if
      seeking.keys.length > 0
    got
  end

end
