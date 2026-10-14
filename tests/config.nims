--path:"../src"
--define:ssl
switch("gc", "orc")
switch("threads", getEnv("WHISKY_TEST_THREADS", "off"))
