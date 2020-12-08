PROJECT = healthmon

include erlang.mk

# Don't warn for these deprecated functions
ERLC_NOWARN= +'nowarn_deprecated_function' +'nowarn_export_all'

# Append these settings
ERLC_OPTS += $(ERLC_NOWARN) +'{parse_transform, lager_transform}'
TEST_ERLC_OPTS += $(ERLC_NOWARN)
