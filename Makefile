all: chibios/ext/fatfs/src/ff.h chibios/ext/lwip/src/include/lwip/api.h

chibios/ext/fatfs/src/ff.h:
	(cd chibios/ext && unar fatfs-0.10b-patched.7z)

chibios/ext/lwip/src/include/lwip/api.h:
	(cd chibios/ext && unar lwip-1.4.1_patched.7z)

clean:
	rm -rf chibios/ext/fatfs chibios/ext/lwip
