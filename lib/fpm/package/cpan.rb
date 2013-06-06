require "fpm/package"
require "json"
require "find"

# Premise: Sidestep all of the historical accidents and just require
# that we have a MYMETA.json v2+ -- for now, just start from there and
# add the download+make+(test?) business later (or not.)

class FPM::Package::CPAN < FPM::Package

  # TODO should really be getting this out of Makefile | Build
  option '--perl', 'PERL_EXECUTABLE',
    'Path to perl.', :default => 'perl'

  # TODO option for cpanm dir / index file

  option '--perl-package', 'PERL_PACKAGE',
    'Package name for perl dependency.', :default => 'perl'

  option '--package-name-prefix', 'PREFIX-',
    'Prefix for output package name', :default => nil 

  option '--lowercase-package-name', :flag, 
    'Lowercase package names (ala debian)', :default => false

  option '--package-naming-scheme', 'SCHEME',
    'Name packages like rpm|deb|pkg', :default => nil

  def input(package)
    path = package # TODO later: download + make
    raise "is not a directory" unless File.directory?(path)

    mymetajson = File.join(path, 'MYMETA.json')
    raise "must have MYMETA.json file #{mymetajson}" unless
      File.exists?(mymetajson)

    @name_fixer = attributes[:cpan_package_naming_scheme] ?
    {
      'rpm' => ->(name) { 'perl-' + name },
      'deb' => ->(name) { 'lib' + name.downcase + '-perl' },
        # XXX except libwww ?
      'solaris' => ->(name) { 'pm_' + name.downcase },
    }[attributes[:cpan_package_naming_scheme]] ||
      raise("invalid naming scheme #{
        attributes[:cpan_package_naming_scheme]}")
    : ->(name) {
      (attributes[:cpan_package_name_prefix] ? 
        (attributes[:cpan_package_name_prefix] + '-') : '') +
      (attributes[:cpan_lowercase_package_name?] ?
        name.downcase : name)
    }

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
    self.name        = fix_name(i['name'])
    self.version     = i['version'].sub(/^v/, '')
    self.license     = i['license'].join(',')
    self.description = i['abstract']
    self.vendor      = i['author'].join(',')
    self.url         = (i['resources']||{})['homepage']

    # TODO +recommends?
    deps = ((i['prereqs']||{})['runtime']||{})['requires']||{}
    depmap = packages_to_dists(deps.keys)
    self.dependencies +=
      [attributes[:cpan_perl_package] + " >= #{perl_version}"]
    self.dependencies += deps.map {|k,v|
      # TODO 'fix' dep names accordingly
      next if k == 'perl'
      dist = depmap[k] or raise "no dist for dep #{k}!"
      next if dist == 'perl'
      v.to_s.split(/,\s+/).map {|req|
        req.sub!(/\bv(\d)/, '\1')
        req = ">= #{req}" if req !~ /[<>=]/
        "#{fix_name(dist)} #{req}"
      }
    }.flatten.select {|x| x}

  end

  def install_to_staging(path)
    # XXX the installbase or such is assumed to have been correct here
    ::Dir.chdir(path) {
      run = File.exists?('Build') ? \
          ['./Build', 'install', '--destdir', staging_path] \
        : File.exists?('Makefile') ? \
          ['make', 'install', 'DESTDIR=' + staging_path] \
        : (raise "no build / make artifacts found")
      safesystem(*run);

      ::Find.find(staging_path) { |f|
        if ::File.basename(f) == 'perllocal.pod'
          ::File.unlink(f)
          d = ::File.dirname(f);
          while(d != staging_path) # walk up empty dirs
            begin; ::Dir.rmdir(d); rescue; end
            d = ::File.dirname(d)
          end
          ::Find.prune
        end
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
    seeking.delete('perl') # TODO should output have perl version dep?
    got = {}
    fh.each_line {|line|
      (p, v, f) = line.chomp.split(/\s+/, 3)
      f or next
      seeking.delete(p) or next
      got[p] = f.match(%r{.*/(.*?)-[^-]+$})[1]
      seeking.keys.length > 0 or break
    }

    # check for core deps
    seeking.keys.each {|k|
      raise "invalid package name '#{k}'" if k =~ /[^a-z0-9:_]/i
      safesystem(attributes[:cpan_perl], "-m#{k}", '-e', 'exit')
      seeking.delete(k)
      got[k] = 'perl'
    }

    # TODO use fpm logger here?
    warn "could not locate dists for #{seeking.keys.join(',')}" if
      seeking.keys.length > 0
    return got
  end

  def fix_name(name)
    @name_fixer.call(name)
  end

  def perl_version
    `#{attributes[:cpan_perl]} -e 'print $^V'`.chomp.
      sub(/^v/, '')
  end

end
