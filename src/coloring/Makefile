include ../common.mk
all: color_omp_base color_serial

%.o: %.cc
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $<

%.o: %.cu
	$(NVCC) $(NVFLAGS) $(INCLUDES) -c $<

color_serial: $(OBJS) serial.o
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(OBJS) serial.o -o $@ -lgomp
	mv $@ $(BIN)

color_omp_base: $(OBJS) omp_base.o
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(OBJS) omp_base.o -o $@ -lgomp
	mv $@ $(BIN)

color_gpu_base: $(OBJS) gpu_base.o
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(OBJS) gpu_base.o -o $@ $(LIBS)
	mv $@ $(BIN)

clean:
	rm *.o
