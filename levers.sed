/^[[:space:]]*exec "\$B\/chrome" \\$/i\
	[ -f "$T/lever.sh" ] && . "$T/lever.sh"
s/NetworkServiceInProcess2\$OMNI_ON/&$CN_EN/
s/\$OMNI_OFF\$WEBGPU_OFF/&$CN_DIS/
s/--optimize-for-size\$JS_LITE/&$CN_JS/
s/\$GPU_OFF \$FULL/$CN_EXTRA &/
