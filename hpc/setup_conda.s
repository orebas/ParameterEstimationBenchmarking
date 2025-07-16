cd $SCRATCH
conda create --prefix env
source activate env/
conda install conda-forge::gcc==11.3
