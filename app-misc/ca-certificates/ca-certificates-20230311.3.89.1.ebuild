# Copyright 1999-2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# The Debian ca-certificates package merely takes the CA database as it exists
# in the nss package and repackages it for use by openssl.
#
# The issue with using the compiled debs directly is two fold:
# - they do not update frequently enough for us to rely on them
# - they pull the CA database from nss tip of tree rather than the release
#
# So we take the Debian source tools and combine them with the latest nss
# release to produce (largely) the same end result.  The difference is that
# now we know our cert database is kept in sync with nss and, if need be,
# can be sync with nss tip of tree more frequently to respond to bugs.

# Where possible, bump to stable/LTS releases of NSS for the last part
# of the version (when not using a pure Debian release).

# When triaging user reports, refer to our wiki for tips:
# https://wiki.gentoo.org/wiki/Certificates#Debugging_certificate_issues

EAPI=8

PYTHON_COMPAT=( python3_{9..11} )

inherit python-any-r1

if [[ ${PV} == *.* ]] ; then
	# Compile from source ourselves.
	PRECOMPILED=false

	DEB_VER=$(ver_cut 1)
	NSS_VER=$(ver_cut 2-)
	RTM_NAME="NSS_${NSS_VER//./_}_RTM"
else
	# Debian precompiled version.
	PRECOMPILED=true
	inherit unpacker
fi

DESCRIPTION="Common CA Certificates PEM files"
HOMEPAGE="https://packages.debian.org/sid/ca-certificates"
NMU_PR=""
if ${PRECOMPILED} ; then
	SRC_URI="mirror://debian/pool/main/c/${PN}/${PN}_${PV}${NMU_PR:++nmu}${NMU_PR}_all.deb"
else
	SRC_URI="
		mirror://debian/pool/main/c/${PN}/${PN}_${DEB_VER}${NMU_PR:++nmu}${NMU_PR}.tar.xz
		https://archive.mozilla.org/pub/security/nss/releases/${RTM_NAME}/src/nss-${NSS_VER}.tar.gz
		cacert? (
			https://dev.gentoo.org/~whissi/dist/ca-certificates/nss-cacert-class1-class3-r2.patch
		)
	"
fi

LICENSE="MPL-1.1"
SLOT="0"
KEYWORDS="~alpha ~amd64 ~arm ~arm64 ~hppa ~ia64 ~loong ~m68k ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86 ~x64-cygwin ~amd64-linux ~x86-linux ~arm64-macos ~ppc-macos ~x64-macos ~sparc-solaris ~sparc64-solaris ~x64-solaris ~x86-solaris ~x86-winnt"
IUSE=""
${PRECOMPILED} || IUSE+=" cacert"

# c_rehash: we run `c_rehash`
# debianutils: we run `run-parts`
CDEPEND="
	sys-apps/debianutils"

BDEPEND="${CDEPEND}"
if ! ${PRECOMPILED} ; then
	BDEPEND+=" ${PYTHON_DEPS}"
fi

DEPEND=""
if ${PRECOMPILED} ; then
	DEPEND+=" !<sys-apps/portage-2.1.10.41"
fi

RDEPEND="${CDEPEND}
	${DEPEND}"

S="${WORKDIR}"

pkg_setup() {
	# For the conversion to having it in CONFIG_PROTECT_MASK,
	# we need to tell users about it once manually first.
	[[ -f "${EPREFIX}"/etc/env.d/98ca-certificates ]] \
		|| ewarn "You should run update-ca-certificates manually after etc-update"

	if ! ${PRECOMPILED} ; then
		python-any-r1_pkg_setup
	fi
}

src_unpack() {
	if ! ${PRECOMPILED} ; then
		default
		# Initial 20200601 deb release had bad naming inside the debian source tarball.
		DEB_S="${WORKDIR}/${PN}-${DEB_VER}"
		DEB_BAD_S="${WORKDIR}/work"
		if [[ -d "${DEB_BAD_S}" ]] && [[ ! -d "${DEB_S}" ]] ; then
			mv "${DEB_BAD_S}" "${DEB_S}"
		fi
	fi

	# Do all the work in the image subdir to avoid conflicting with source
	# dirs in ${WORKDIR}.  Need to perform everything in the offset #381937
	mkdir -p "image/${EPREFIX}" || die
	cd "image/${EPREFIX}" || die

	${PRECOMPILED} && unpacker_src_unpack
}

src_prepare() {
	cd "image/${EPREFIX}" || die

	if ! ${PRECOMPILED} ; then
		mkdir -p usr/sbin || die
		cp -p "${S}"/${PN}/sbin/update-ca-certificates \
			usr/sbin/ || die

		if use cacert ; then
			pushd "${S}"/nss-${NSS_VER} >/dev/null || die
			eapply "${DISTDIR}"/nss-cacert-class1-class3-r2.patch
			popd >/dev/null || die
		fi
	fi

	default
	eapply -p2 "${FILESDIR}"/${PN}-20150426-root.patch

	pushd "${S}/${PN}" >/dev/null || die
	# We patch out the dep on cryptography as it's not particularly useful
	# for us. Please see the discussion in bug #821706. Not to be removed lightly!
	eapply "${FILESDIR}"/${PN}-20230311.3.89-no-cryptography.patch
	popd >/dev/null || die

	local relp=$(echo "${EPREFIX}" | sed -e 's:[^/]\+:..:g')
	sed -i \
		-e '/="$ROOT/s:ROOT:ROOT'"${EPREFIX}"':' \
		-e '/RELPATH="\.\./s:"$:'"${relp}"'":' \
		usr/sbin/update-ca-certificates || die
}

src_compile() {
	cd "image/${EPREFIX}" || die

	if ! ${PRECOMPILED} ; then
		local d="${S}/${PN}/mozilla" c="usr/share/${PN}"

		# Grab the database from the nss sources.
		cp "${S}"/nss-${NSS_VER}/nss/lib/ckfw/builtins/{certdata.txt,nssckbi.h} "${d}" || die
		emake -C "${d}"

		# Now move the files to the same places that the precompiled would.
		mkdir -p etc/ssl/certs \
			etc/ca-certificates/update.d \
			"${c}"/mozilla \
			|| die
		if use cacert ; then
			mkdir -p "${c}"/cacert.org || die
			mv "${d}"/CA_Cert_Signing_Authority.crt \
				"${c}"/cacert.org/cacert.org_class1.crt || die
			mv "${d}"/CAcert_Class_3_Root.crt \
				"${c}"/cacert.org/cacert.org_class3.crt || die
		fi
		mv "${d}"/*.crt "${c}"/mozilla/ || die
	else
		mv usr/share/doc/{ca-certificates,${PF}} || die
	fi

	(
		echo "# Automatically generated by ${CATEGORY}/${PF}"
		echo "# $(date -u)"
		echo "# Do not edit."
		cd "${c}" || die
		find * -name '*.crt' | LC_ALL=C sort
	) > etc/ca-certificates.conf

	sh usr/sbin/update-ca-certificates --root "${S}/image" || die
}

src_install() {
	cp -pPR image/* "${D}"/ || die
	if ! ${PRECOMPILED} ; then
		cd ${PN} || die
		doman sbin/*.8
		dodoc debian/README.* examples/ca-certificates-local/README
	fi

	echo 'CONFIG_PROTECT_MASK="/etc/ca-certificates.conf"' > 98ca-certificates || die
	doenvd 98ca-certificates
}

pkg_postinst() {
	if [[ -d "${EROOT}/usr/local/share/ca-certificates" ]] ; then
		# If the user has local certs, we need to rebuild again
		# to include their stuff in the db.
		# However it's too overzealous when the user has custom certs in place.
		# --fresh is to clean up dangling symlinks
		"${EROOT}"/usr/sbin/update-ca-certificates --root "${ROOT}"
	fi

	if [[ -n "$(find -L "${EROOT}"/etc/ssl/certs/ -type l)" ]] ; then
		ewarn "Removing the following broken symlinks:"
		ewarn "$(find -L "${EROOT}"/etc/ssl/certs/ -type l -printf '%p -> %l\n' -delete)"
	fi
}
