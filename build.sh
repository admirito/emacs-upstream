#!/bin/sh
# Runs inside the build container. Builds Emacs $VERSION from /out/emacs-$VERSION.tar.xz
# with the $TOOLKIT toolkit and packages it as /out/${PACKAGE}_${DEBVERSION}_<arch>.deb,
# maintained by $MAINTAINER and installed under /opt/emacs-upstream.
#
# set -e misses a failure before the last command of a pipeline, and one inside
# eval "$(...)", so each result that comes out of either is checked by hand.
set -eu

# The commands the package links into /usr/bin, each with its man page.
commands="emacs emacsclient etags ebrowse"

fail() {
    echo "build.sh: $*" >&2
    exit 1
}

# Each flavor builds with the toolkit flags of Ubuntu's own package for that toolkit,
# and replaces the other flavor: both install into the same folder.
case $TOOLKIT in
    gtk3) toolkit_flags="--with-x-toolkit=gtk3" other=emacs-upstream-lucid ;;
    lucid) toolkit_flags="--with-x-toolkit=lucid --with-toolkit-scroll-bars --without-gsettings"
           other=emacs-upstream ;;
    *) fail "unknown TOOLKIT $TOOLKIT" ;;
esac

arch=$(dpkg --print-architecture)
deb=${PACKAGE}_${DEBVERSION}_$arch
root=/build/$deb
prefix=/opt/emacs-upstream

mkdir -p /build
cd /build
tar -xf /out/emacs-"$VERSION".tar.xz
cd emacs-"$VERSION"

# The Debian packaging tools read these: dpkg-buildflags takes the package's name and
# version for the ELF note that lets crash reports name the package, and
# dpkg-shlibdeps needs a control file to run at all.
mkdir debian
printf 'Source: emacs-upstream\n\nPackage: %s\nArchitecture: any\n' "$PACKAGE" >debian/control
cat >debian/changelog <<EOF
emacs-upstream ($DEBVERSION) unstable; urgency=medium

  * GNU Emacs $VERSION.

 -- $MAINTAINER  $(date -R)
EOF

# The flags Ubuntu builds its packages with: hardening and frame pointers, but no LTO,
# which Ubuntu turns off for its own emacs and Emacs's INSTALL warns "tends to cause
# crashes and to make Emacs slower". Called in the source directory, which the
# flags' file-prefix map names.
flags=$(DEB_BUILD_MAINT_OPTIONS=optimize=-lto dpkg-buildflags --export=sh)
eval "$flags"

# Native compilation needs the gcc whose libgccjit Ubuntu's emacs builds with, which
# can be older than the release's default gcc (14 against 15 on 26.04).
gccjit=$(dpkg-query -W -f '${db:Status-Abbrev}${Package}\n' 'libgccjit-*-dev' |
    sed -n 's/^ii libgccjit-\(.*\)-dev$/\1/p' | head -1)
[ -n "$gccjit" ] || fail "no libgccjit-*-dev is installed; is this the build image?"

# Features named here make configure fail when their library is missing, where it
# would otherwise leave them out without a word; test.sh checks the rest.
# - aot compiles all of Emacs's Lisp to native code now, rather than in each user's
#   Emacs in the background the first time a file is loaded.
# - mailutils, as Ubuntu builds: Rmail then uses GNU Mailutils' movemail, which
#   speaks POP and IMAP over TLS, instead of building Emacs's own.
# - selinux, which Ubuntu's emacs has and Emacs 31 no longer turns on by itself.
# - Without build details, the container's hostname and the build time stay out of
#   the binary.
# - /usr/local/share/emacs is searched for Lisp, as by Ubuntu's emacs.
# shellcheck disable=SC2086 # toolkit_flags is several flags
CC=gcc-$gccjit ./configure \
    --prefix=$prefix \
    --with-native-compilation=aot \
    $toolkit_flags \
    --with-tree-sitter \
    --with-dbus \
    --with-mailutils \
    --with-selinux \
    --disable-build-details \
    --enable-locallisppath=/usr/local/share/emacs/$VERSION/site-lisp:/usr/local/share/emacs/site-lisp:$prefix/share/emacs/$VERSION/site-lisp:$prefix/share/emacs/site-lisp
make -j"$(nproc)"
# The build leaves a native-compiled trampoline in lisp/, which make install would
# copy into the installed Lisp and subdirs.el would put on load-path. Emacs makes
# trampolines when it needs them.
rm -rf lisp/native-lisp
make install DESTDIR="$root"

for p in $commands; do
    [ -e "$root$prefix/bin/$p" ] || fail "Emacs $VERSION installs no $p"
done

# Emacs's own unit, where systemd finds it, named so as not to clash with the
# emacs.service of Ubuntu's emacs-common.
mkdir -p "$root"/usr/lib/systemd/user
mv "$root$prefix"/lib/systemd/user/emacs.service "$root"/usr/lib/systemd/user/emacs-upstream.service
rmdir "$root$prefix"/lib/systemd/user "$root$prefix"/lib/systemd

# Ubuntu's emacs keeps /usr/bin/emacs, because its add-on packages compile their Lisp
# by running it with PATH reset to /usr/bin, and Lisp compiled by a newer Emacs may
# not load in an older one. Users get this Emacs from PATH instead, and its desktop
# entries and icons from XDG_DATA_DIRS: the profile file sets both for login shells,
# the environment.d file for the desktop session, the way snapd adds /snap/bin. The
# 990 sorts it after systemd's 99-environment.conf, which sets PATH outright.
mkdir -p "$root"/etc/profile.d "$root"/usr/lib/environment.d
cat >"$root"/etc/profile.d/emacs-upstream.sh <<EOF
# Put $prefix first on PATH, and its desktop entries first in XDG_DATA_DIRS,
# ahead of Ubuntu's emacs.
case ":\$PATH:" in
    *:$prefix/bin:*) ;;
    *) PATH=$prefix/bin:\$PATH ;;
esac
case ":\${XDG_DATA_DIRS:-}:" in
    *:$prefix/share:*) ;;
    *) XDG_DATA_DIRS=$prefix/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share} ;;
esac
export PATH XDG_DATA_DIRS
EOF
cat >"$root"/usr/lib/environment.d/990-emacs-upstream.conf <<EOF
# Put $prefix first on PATH, and its desktop entries first in XDG_DATA_DIRS,
# ahead of Ubuntu's emacs.
PATH=$prefix/bin:\${PATH}
XDG_DATA_DIRS=$prefix/share:\${XDG_DATA_DIRS:-/usr/local/share/:/usr/share/}
EOF

# The programs, found by their ELF header. The native-compiled .eln files are shared
# objects that link only libc, so they need no place in the Depends scan.
programs=$(find "$root" -type f -perm -u+x ! -name '*.eln' | while read -r f; do
    if [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = 177ELF ]; then echo "$f"; fi
done)
[ -n "$programs" ] || fail "found no programs under $root"

# Stripped as Ubuntu's packages are: debug info is most of the size of the programs.
for f in $programs; do
    strip --remove-section=.comment --remove-section=.note "$f"
done
find "$root" -name '*.eln' -exec strip --remove-section=.comment --remove-section=.note --strip-unneeded {} +

# shellcheck disable=SC2046,SC2086 # one -e<file> argument per program
substvars=$(dpkg-shlibdeps -O $(printf -- '-e%s ' $programs))
case $substvars in
    shlibs:Depends=?*) depends=${substvars#shlibs:Depends=} ;;
    *) fail "dpkg-shlibdeps gave no Depends: $substvars" ;;
esac
size=$(du -sk "$root" | cut -f1)

# mailutils is suggested, not recommended as Ubuntu's emacs does: it recommends a mail
# server, so apt would install postfix with it. gcc and git build tree-sitter
# grammars, which Emacs offers to do when a mode needs one.
mkdir -p "$root"/DEBIAN
cat >"$root"/DEBIAN/control <<EOF
Package: $PACKAGE
Version: $DEBVERSION
Architecture: $arch
Maintainer: $MAINTAINER
Section: editors
Priority: optional
Installed-Size: $size
Depends: $depends
Recommends: fonts-noto-color-emoji
Suggests: mailutils, gcc, git
Conflicts: $other
Replaces: $other
Homepage: https://www.gnu.org/software/emacs/
Description: GNU Emacs $VERSION ($TOOLKIT), built from the signed release tarball
 Installed under $prefix, beside Ubuntu's own emacs packages.
 It comes first on users' PATH, and provides the commands
 $commands in /usr/bin while Ubuntu's emacs
 is not installed.
 .
 Built by https://github.com/admirito/emacs-upstream
EOF
echo /etc/profile.d/emacs-upstream.sh >"$root"/DEBIAN/conffiles

# Ubuntu's emacs packages register the same commands, and the same man page links, at
# priority 28; this package's 20 keeps them Ubuntu's while both are installed. The
# postinst runs on every call, as Ubuntu's does, so that an aborted removal or
# upgrade gets its links back.
cat >"$root"/DEBIAN/postinst <<EOF
#!/bin/sh
set -e
for p in $commands; do
    update-alternatives --install /usr/bin/\$p \$p $prefix/bin/\$p 20 \\
        --slave /usr/share/man/man1/\$p.1.gz \$p.1.gz $prefix/share/man/man1/\$p.1.gz
done
EOF
cat >"$root"/DEBIAN/prerm <<EOF
#!/bin/sh
set -e
if [ "\$1" != upgrade ]; then
    for p in $commands; do
        update-alternatives --remove \$p $prefix/bin/\$p
    done
fi
EOF
chmod 755 "$root"/DEBIAN/postinst "$root"/DEBIAN/prerm

# dpkg --verify and debsums check the installed files against this list.
(cd "$root" && find . -type f ! -path './DEBIAN/*' ! -path './etc/*' -printf '%P\0' | xargs -0 md5sum) \
    >"$root"/DEBIAN/md5sums

dpkg-deb --build --root-owner-group "$root" /out/"$deb".deb

# Hand the .deb to whoever owns the output folder: the host user under rootless podman
# (where that user is root inside) as well as under docker.
chown "$(stat -c %u:%g /out)" /out/"$deb".deb
