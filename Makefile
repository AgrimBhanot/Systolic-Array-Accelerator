OUTDIR = Outputs
WAVEDIR = Waveforms

all: pe grid top

$(OUTDIR):
	mkdir -p $(OUTDIR)

$(WAVEDIR):
	mkdir -p $(WAVEDIR)

pe: | $(OUTDIR) $(WAVEDIR)
	iverilog -g2012 -o $(OUTDIR)/pe_sim.vvp \
		processing_element.sv \
		Testbenches/tb_processing_element.sv
	vvp $(OUTDIR)/pe_sim.vvp

grid: | $(OUTDIR) $(WAVEDIR)
	iverilog -g2012 -o $(OUTDIR)/grid_sim.vvp \
		processing_element.sv \
		systolic_array_grid.sv \
		Testbenches/tb_systolic_array_grid.sv
	vvp $(OUTDIR)/grid_sim.vvp

top: | $(OUTDIR) $(WAVEDIR)
	iverilog -g2012 -o $(OUTDIR)/top.vvp -f files.f
	vvp $(OUTDIR)/top.vvp

clean:
	rm -rf $(OUTDIR) $(WAVEDIR)




# make pe
# make grid
# make top
# make clean