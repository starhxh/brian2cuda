{% macro cu_file() %}
#include "code_objects/{{codeobj_name}}.h"
#include "brianlib/common_math.h"
#include "brianlib/stdint_compat.h"
#include <cmath>
#include <stdint.h>
#include <ctime>
#include <stdio.h>
{% block extra_headers %}
{% endblock %}

////// SUPPORT CODE ///////
namespace {
	{% block extra_device_helper %}
	{% endblock %}
	{{support_code_lines|autoindent}}
}

{{hashdefine_lines|autoindent}}

{% block kernel %}
__global__ void
{% if launch_bounds %}
__launch_bounds__(1024, {{sm_multiplier}})
{% endif %}
kernel_{{codeobj_name}}(
	unsigned int _N,
	unsigned int THREADS_PER_BLOCK,
	///// DEVICE_PARAMETERS /////
	%DEVICE_PARAMETERS%
	)
{
	{# USES_VARIABLES { N } #}
	using namespace brian;

	unsigned int tid = threadIdx.x;
	unsigned int bid = blockIdx.x;
	unsigned int _idx = bid * THREADS_PER_BLOCK + tid;
	unsigned int _vectorisation_idx = _idx;
	///// KERNEL_VARIABLES /////
	%KERNEL_VARIABLES%

	assert(THREADS_PER_BLOCK == blockDim.x);

	{% block additional_variables %}
	{% endblock %}

	{% block num_thread_check %}
	if(_idx >= _N)
	{
		return;
	}
	{% endblock %}

	{% block maincode %}
	{% block maincode_inner %}
	
	///// scalar_code /////
	{{scalar_code|autoindent}}
	
	{
		///// vector_code /////
		{{vector_code|autoindent}}
	}
	{% endblock maincode_inner %}
	{% endblock maincode %}
}
{% endblock kernel %}

void _run_{{codeobj_name}}()
{	
	{# USES_VARIABLES { N } #}
	using namespace brian;
	
	{% block profiling_start %}
	{% if profile and profile == 'blocking'%}
	{{codeobj_name}}_timer_start = std::clock();
	{% elif profile %}
	cudaEventRecord({{codeobj_name}}_timer_start);
	{% endif %}
	{% endblock %}

	{% block define_N %}
	{# N is a constant in most cases (NeuronGroup, etc.), but a scalar array for
           synapses, we therefore have to take care to get its value in the right
           way. #}
	const int _N = {{constant_or_scalar('N', variables['N'])}};
	{% endblock %}

	///// CONSTANTS ///////////
	%CONSTANTS%

	{% block extra_maincode %}
	{% endblock %}

	{% block prepare_kernel %}
	static int num_threads, num_blocks;
	static bool first_run = true;
	if (first_run)
	{
		{% block prepare_kernel_inner %}
		// get number of blocks and threads
		{% if calc_occupancy %}
		int min_num_threads; // The minimum grid size needed to achieve the
							 // maximum occupancy for a full device launch

		cudaOccupancyMaxPotentialBlockSize(&min_num_threads, &num_threads,
				kernel_{{codeobj_name}}, 0, 0);  // last args: dynamicSMemSize, blockSizeLimit

		// Round up according to array size
		num_blocks = (_N + num_threads - 1) / num_threads;
		{% else %}
		num_blocks = num_parallel_blocks;
		while(num_blocks * max_threads_per_block < _N)
		{
			num_blocks *= 2;
		}
		num_threads = min(max_threads_per_block, (int)ceil(_N/(double)num_blocks));
		{% endif %}
		{% endblock prepare_kernel_inner %}

		{% block occupancy %}
		// calculate theoretical occupancy
		int max_active_blocks;
		cudaOccupancyMaxActiveBlocksPerMultiprocessor(&max_active_blocks,
				kernel_{{codeobj_name}}, num_threads, 0);

		float occupancy = (max_active_blocks * num_threads / num_threads_per_warp) /
		                  (float)(max_threads_per_sm / num_threads_per_warp);
		{% endblock occupancy %}


        // check if we have enough ressources to call kernel with given number
        // of blocks and threads
		struct cudaFuncAttributes funcAttrib;
		cudaFuncGetAttributes(&funcAttrib, kernel_{{codeobj_name}});
		if (num_threads > funcAttrib.maxThreadsPerBlock)
		{
			// use the max num_threads before launch failure
			num_threads = funcAttrib.maxThreadsPerBlock;
	    	printf("WARNING Not enough ressources available to call "
                   "kernel_{{codeobj_name}} "
                   "with maximum possible threads per block (%u). "
                   "Reducing num_threads to %u. (Kernel needs %i "
                   "registers per block, %i bytes of "
                   "statically-allocated shared memory per block, %i "
                   "bytes of local memory per thread and a total of %i "
                   "bytes of user-allocated constant memory)\n",
                   max_threads_per_block, num_threads, funcAttrib.numRegs,
                   funcAttrib.sharedSizeBytes, funcAttrib.localSizeBytes,
                   funcAttrib.constSizeBytes);
		}
		{% block extra_info_msg %}
		{% endblock %}
		{% block kernel_info %}
		else
		{
            printf("INFO kernel_{{codeobj_name}}\n"
                   "\t%u blocks\n"
                   "\t%u threads\n"
                   "\t%i registers per block\n"
                   "\t%i bytes statically-allocated shared memory per block\n"
                   "\t%i bytes local memory per thread\n"
                   "\t%i bytes user-allocated constant memory\n"
                   {% if calc_occupancy %}
                   "\t%.3f theoretical occupancy\n",
                   {% else %}
                   "",
                   {% endif %}
                   num_blocks, num_threads, funcAttrib.numRegs,
                   funcAttrib.sharedSizeBytes, funcAttrib.localSizeBytes,
                   funcAttrib.constSizeBytes{% if calc_occupancy %}, occupancy{% endif %});
		}
		{% endblock %}
		first_run = false;
	}
	{% endblock prepare_kernel %}

	{% block extra_kernel_call %}
	{% endblock %}

	{% block kernel_call %}
	kernel_{{codeobj_name}}<<<num_blocks, num_threads>>>(
			_N,
			num_threads,
			///// HOST_PARAMETERS /////
			%HOST_PARAMETERS%
		);

	cudaError_t status = cudaGetLastError();
	if (status != cudaSuccess)
	{
		printf("ERROR launching kernel_{{codeobj_name}} in %s:%d %s\n",
				__FILE__, __LINE__, cudaGetErrorString(status));
		_dealloc_arrays();
		exit(status);
	}
	{% endblock kernel_call %}

	{% block profiling_stop %}
	{% if profile and profile == 'blocking'%}
	cudaDeviceSynchronize();
	{{codeobj_name}}_timer_stop = std::clock();
	{% elif profile %}
	cudaEventRecord({{codeobj_name}}_timer_stop);
	{% endif %}
	{% endblock %}
}

{% block extra_functions_cu %}
{% endblock %}

{% endmacro %}


{% macro h_file() %}
#ifndef _INCLUDED_{{codeobj_name}}
#define _INCLUDED_{{codeobj_name}}

#include "objects.h"

void _run_{{codeobj_name}}();

{% block extra_functions_h %}
{% endblock %}

#endif
{% endmacro %}
