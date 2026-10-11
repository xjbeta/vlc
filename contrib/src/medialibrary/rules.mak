MEDIALIBRARY_VERSION := 0.13.2
MEDIALIBRARY_URL := $(VIDEOLAN_GIT)/videolan/medialibrary/-/archive/$(MEDIALIBRARY_VERSION)/medialibrary-$(MEDIALIBRARY_VERSION).tar.bz2

ifndef HAVE_WINSTORE
PKGS += medialibrary
endif
ifeq ($(call need_pkg,"medialibrary >= 0.13.0"),)
PKGS_FOUND += medialibrary
endif

DEPS_medialibrary = sqlite $(DEPS_sqlite)

$(TARBALLS)/medialibrary-$(MEDIALIBRARY_VERSION).tar.bz2:
	$(call download_pkg,$(MEDIALIBRARY_URL),medialibrary)

.sum-medialibrary: medialibrary-$(MEDIALIBRARY_VERSION).tar.bz2

medialibrary: medialibrary-$(MEDIALIBRARY_VERSION).tar.bz2 .sum-medialibrary
	$(UNPACK)
	# Eriri: give sqlite a busy timeout, and keep a sqlite error from escaping a
	# parser thread (which calls std::terminate). Both are needed for the media
	# library to survive concurrent database access.
	$(APPLY) $(SRC)/medialibrary/0001-wait-for-sqlite-locks-instead-of-failing-at-once.patch
	$(MOVE)

.medialibrary: medialibrary crossfile.meson
	$(MESONCLEAN)
	$(MESON) -Dlibvlc=disabled -Dlibtool_workaround=true
	+$(MESONBUILD)
	touch $@
