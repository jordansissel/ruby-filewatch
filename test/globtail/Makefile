test:
	@for file in test*.sh; do \
		echo "$$file:" ; \
		./$$file || exit 1 ; \
		echo "PASS" ; \
	done
