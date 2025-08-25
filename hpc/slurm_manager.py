#!/usr/bin/env python3

"""
SLURM Array Job Queue Manager

This script manages SLURM array jobs by submitting them in batches to respect
CPU limits. It monitors job completion and submits new batches as resources
become available.

Usage:
    python slurm_queue_manager.py results/FINAL100 --max-cpus=1800
"""

import subprocess
import time
import re
import sys
import argparse
from pathlib import Path
from datetime import datetime
import json

class SlurmQueueManager:
    def __init__(self, results_dir, max_batch_size=100, max_cpus=1000, 
                 ping_interval=30, job_scripts=None, array_per_script=5000):
        self.results_dir = results_dir
        self.max_cpus = max_cpus
        self.ping_interval = ping_interval
        self.array_per_script = array_per_script
        
        # Cap batch size if it's larger than max_cpus
        if max_batch_size > max_cpus:
            self.max_batch_size = max(1, max_cpus // 4)  # Quarter of max_cpus, minimum 1
            print(f"⚠️  Batch size {max_batch_size} exceeds max CPUs {max_cpus}")
            print(f"   Capping batch size to {self.max_batch_size} (quarter of max CPUs)")
        else:
            self.max_batch_size = max_batch_size

        # Find available job scripts
        self.hpc_dir = Path("hpc")
        if job_scripts:
            # Use provided scripts, convert to Path objects
            self.job_scripts = [Path(script) for script in job_scripts]
        else:
            # Use default scripts
            self.job_scripts = [
                self.hpc_dir / "array_job_amigo2.s",
                self.hpc_dir / "array_job_odepe.s", 
                self.hpc_dir / "array_job_pe.s",
                self.hpc_dir / "array_job_sciml.s"
            ]
        
        # Job tracking
        self.pending_jobs = []
        self.active_jobs = {}
        self.completed_jobs = []
        self.failed_jobs = []
        self.current_cpu_usage = 0
        
    def _get_cpus_per_task(self, script_path):
        """Extract CPU requirements from job script"""
        try:
            with open(script_path, 'r') as f:
                content = f.read()
                
                # Look for various CPU specification patterns
                patterns = [
                    r'#SBATCH\s+--cpus-per-task[=\s]+(\d+)',
                    r'#SBATCH\s+-c\s+(\d+)',
                    r'#SBATCH\s+--ntasks-per-node[=\s]+(\d+)',
                    r'#SBATCH\s+-n\s+(\d+)'
                ]
                
                for pattern in patterns:
                    match = re.search(pattern, content)
                    if match:
                        return int(match.group(1))
                        
                # Look for ntasks * cpus-per-task
                ntasks_match = re.search(r'#SBATCH\s+--ntasks[=\s]+(\d+)', content)
                cpus_match = re.search(r'#SBATCH\s+--cpus-per-task[=\s]+(\d+)', content)
                
                if ntasks_match and cpus_match:
                    return int(ntasks_match.group(1)) * int(cpus_match.group(1))
                elif ntasks_match:
                    return int(ntasks_match.group(1))
                    
        except Exception as e:
            print(f"Warning: Could not parse CPU requirements from {script_path}: {e}")
        
        # Default fallback
        return 1
    
    def _submit_job_batch(self, script_path, start_idx, end_idx):
        """Submit a batch of array jobs"""
        array_spec = f"{start_idx}-{end_idx}"
        cpus_per_task = self._get_cpus_per_task(script_path)
        array_size = end_idx - start_idx + 1
        total_cpus = cpus_per_task * array_size
        
        cmd = [
            "sbatch", 
            f"--array={array_spec}",
            str(script_path),
            str(self.results_dir)
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            output = result.stdout.strip()
            
            # Extract job ID from sbatch output
            job_match = re.search(r'Submitted batch job (\d+)', output)
            if job_match:
                job_id = job_match.group(1)
                job_info = {
                    'job_id': job_id,
                    'script': script_path.name,
                    'array_range': f"{start_idx}-{end_idx}",
                    'submit_time': datetime.now(),
                    'cpus_per_task': cpus_per_task,
                    'array_size': array_size,
                    'total_cpus': total_cpus
                }
                self.active_jobs[job_id] = job_info
                self.current_cpu_usage += total_cpus
                print(f"✓ Submitted job {job_id}: {script_path.name} [{array_spec}] "
                      f"({cpus_per_task} CPUs/task × {array_size} tasks = {total_cpus} CPUs)")
                return job_id
            else:
                print(f"✗ Failed to parse job ID from: {output}")
                return None
                
        except subprocess.CalledProcessError as e:
            print(f"✗ Failed to submit {script_path.name} [{array_spec}]: {e}")
            print(f"  stdout: {e.stdout}")
            print(f"  stderr: {e.stderr}")
            return None
    
    def _check_job_status(self, job_id):
        """Check the status of a specific job"""
        try:
            cmd = ["squeue", "-j", job_id, "-h", "-o", "%T"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            
            if result.stdout.strip():
                return result.stdout.strip()
            else:
                # Job not in queue, check if it completed
                return "COMPLETED"
                
        except subprocess.CalledProcessError:
            # Job not found in queue, assume completed
            return "COMPLETED"
    
    def _get_job_array_status(self, job_id):
        """Get detailed status of array job elements"""
        try:
            cmd = ["sacct", "-j", job_id, "-o", "JobID,State", "-n", "-P"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            
            status_counts = {}
            for line in result.stdout.strip().split('\n'):
                if line and '|' in line:
                    job_part, state = line.split('|', 1)
                    if '_' in job_part:  # Array job element
                        status_counts[state] = status_counts.get(state, 0) + 1
            
            return status_counts
            
        except subprocess.CalledProcessError:
            return {}
    
    def _prepare_job_queue(self):
        """Prepare the queue of jobs to be submitted"""
        self.pending_jobs = []
        
        print(f"📋 Analyzing job scripts and preparing queue...")
        
        for script in self.job_scripts:
            cpus_per_task = self._get_cpus_per_task(script)
            
            print(f"   - {script.name}: {self.array_per_script} tasks, {cpus_per_task} CPUs per task")
            
            # Split into batches
            for start_idx in range(0, self.array_per_script, self.max_batch_size):
                end_idx = min(start_idx + self.max_batch_size - 1, self.array_per_script - 1)
                array_size = end_idx - start_idx + 1
                total_cpus = cpus_per_task * array_size
                
                job_batch = {
                    'script': script,
                    'start_idx': start_idx,
                    'end_idx': end_idx,
                    'cpus_per_task': cpus_per_task,
                    'array_size': array_size,
                    'total_cpus': total_cpus
                }
                self.pending_jobs.append(job_batch)
        
        total_batches = len(self.pending_jobs)
        total_tasks = sum(job['array_size'] for job in self.pending_jobs)
        total_cpu_hours = sum(job['total_cpus'] for job in self.pending_jobs)
        
        print(f"\n📊 Queue Summary:")
        print(f"   Total job batches: {total_batches}")
        print(f"   Total tasks: {total_tasks}")
        print(f"   Total CPU slots needed: {total_cpu_hours}")
        print(f"   Available CPU limit: {self.max_cpus}")
        print()
    
    def _submit_next_batches(self):
        """Submit the next batch of jobs up to the CPU limit"""
        while self.pending_jobs:
            # Check if we have enough CPU capacity for the next job
            next_job = self.pending_jobs[0]
            needed_cpus = next_job['total_cpus']
            
            if self.current_cpu_usage + needed_cpus > self.max_cpus:
                # Not enough CPU capacity, wait for jobs to complete
                break
            
            # Submit the job
            job_batch = self.pending_jobs.pop(0)
            job_id = self._submit_job_batch(
                job_batch['script'],
                job_batch['start_idx'],
                job_batch['end_idx']
            )
            
            if not job_id:
                # Submission failed, mark as failed
                print(f"✗ Marking {job_batch['script'].name} [{job_batch['start_idx']}-{job_batch['end_idx']}] as failed")
                self.failed_jobs.append(job_batch)
    
    def _check_active_jobs(self):
        """Check status of active jobs and move completed ones"""
        completed_job_ids = []
        
        for job_id, job_info in self.active_jobs.items():
            status = self._check_job_status(job_id)
            
            if status in ["COMPLETED", "FAILED", "CANCELLED", "TIMEOUT"]:
                completed_job_ids.append(job_id)
                
                # Release CPU resources
                self.current_cpu_usage -= job_info['total_cpus']
                
                if status == "COMPLETED":
                    print(f"✓ Job {job_id} completed: {job_info['script']} [{job_info['array_range']}] "
                          f"(freed {job_info['total_cpus']} CPUs)")
                    self.completed_jobs.append(job_info)
                else:
                    print(f"✗ Job {job_id} failed ({status}): {job_info['script']} [{job_info['array_range']}] "
                          f"(freed {job_info['total_cpus']} CPUs)")
                    self.failed_jobs.append(job_info)
        
        # Remove completed jobs from active list
        for job_id in completed_job_ids:
            del self.active_jobs[job_id]
    
    def _print_status(self):
        """Print current status"""
        cpu_utilization = (self.current_cpu_usage / self.max_cpus) * 100 if self.max_cpus > 0 else 0
        
        print(f"\n📊 Status Update [{datetime.now().strftime('%H:%M:%S')}]:")
        print(f"   CPU Usage:      {self.current_cpu_usage}/{self.max_cpus} ({cpu_utilization:.1f}%)")
        print(f"   Active jobs:    {len(self.active_jobs)}")
        print(f"   Pending jobs:   {len(self.pending_jobs)}")
        print(f"   Completed jobs: {len(self.completed_jobs)}")
        print(f"   Failed jobs:    {len(self.failed_jobs)}")
        
        if self.active_jobs:
            print(f"   Currently running:")
            for job_id, job_info in self.active_jobs.items():
                runtime = datetime.now() - job_info['submit_time']
                print(f"     - Job {job_id}: {job_info['script']} [{job_info['array_range']}] "
                      f"({job_info['total_cpus']} CPUs, running {runtime})")
        
        if self.pending_jobs:
            next_job = self.pending_jobs[0]
            print(f"   Next job needs: {next_job['total_cpus']} CPUs "
                  f"({next_job['script'].name} [{next_job['start_idx']}-{next_job['end_idx']}])")
    
    def get_jobs_to_run(self):
        """
        Check available CPU capacity and return a list of jobs that can be submitted.
        Returns a list of job batches that fit within the current CPU limit.
        """
        available_cpus = self.max_cpus - self.current_cpu_usage
        jobs_to_run = []
        
        # Go through pending jobs and find those that fit in available CPU capacity
        remaining_cpus = available_cpus
        for job_batch in self.pending_jobs[:]:  # Create a copy to avoid modification during iteration
            if job_batch['total_cpus'] <= remaining_cpus:
                jobs_to_run.append(job_batch)
                remaining_cpus -= job_batch['total_cpus']
        
        return jobs_to_run
    
    def run(self):
        print(f"🚀 Starting SLURM Queue Manager")
        print(f"   Results directory: {self.results_dir}")
        print(f"   Batch size: {self.max_batch_size}")
        print(f"   Max CPUs: {self.max_cpus}")
        print(f"   Ping interval: {self.ping_interval}s")
        print()
        
        # Prepare job queue
        self._prepare_job_queue()
        
        # Main execution loop
        start_time = datetime.now()
        
        while self.pending_jobs or self.active_jobs:
            # Check status of active jobs first
            self._check_active_jobs()
            
            # Get jobs that can be submitted based on available CPU capacity
            jobs_to_run = self.get_jobs_to_run()
            
            # Submit the jobs that fit in available CPU capacity
            for job_batch in jobs_to_run:
                job_id = self._submit_job_batch(
                    job_batch['script'],
                    job_batch['start_idx'],
                    job_batch['end_idx']
                )
                
                if job_id:
                    # Successfully submitted, remove from pending jobs
                    self.pending_jobs.remove(job_batch)
                else:
                    # Submission failed, mark as failed and remove from pending
                    print(f"✗ Marking {job_batch['script'].name} [{job_batch['start_idx']}-{job_batch['end_idx']}] as failed")
                    self.failed_jobs.append(job_batch)
                    self.pending_jobs.remove(job_batch)
            
            # Print status
            self._print_status()
            
            # Wait before next check
            if self.pending_jobs or self.active_jobs:
                time.sleep(self.ping_interval)
        
        # Final summary
        total_time = datetime.now() - start_time
        print(f"\n🎉 All jobs completed!")
        print(f"   Total time: {total_time}")
        print(f"   Completed: {len(self.completed_jobs)}")
        print(f"   Failed: {len(self.failed_jobs)}")
        
        if self.failed_jobs:
            print(f"\n⚠️  Failed jobs:")
            for job in self.failed_jobs:
                if isinstance(job, dict) and 'script' in job:
                    script_name = job['script'].name if hasattr(job['script'], 'name') else str(job['script'])
                    print(f"   - {script_name} [{job.get('start_idx', '?')}-{job.get('end_idx', '?')}]")
                else:
                    print(f"   - {job.get('script', 'unknown')}")

def main():
    parser = argparse.ArgumentParser(description='SLURM Array Job Queue Manager')
    parser.add_argument('results_dir', help='Results directory to pass to job scripts')
    parser.add_argument('--max-cpus', type=int, required=True,
                       help='Maximum number of CPUs to use simultaneously')
    parser.add_argument('--array-per-script', type=int, required=True,
                        help='Number of array elements per script')
    parser.add_argument('--max-batch-size', type=int, default=100,
                       help='Number of array elements per batch (default: 100)')
    parser.add_argument('--ping-interval', type=int, default=1,
                       help='Status check interval in seconds (default: 1)')
    parser.add_argument('--scripts', nargs='*', 
                       help='HPC job scripts to run (default: array_job_amigo2.s array_job_odepe.s array_job_pe.s array_job_sciml.s)')

    args = parser.parse_args()
    
    # Validate results directory
    results_path = Path(args.results_dir)
    if not results_path.exists():
        print(f"Error: Results directory '{args.results_dir}' does not exist")
        sys.exit(1)
    
    # Create and run manager
    manager = SlurmQueueManager(
        results_dir=args.results_dir,
        max_batch_size=args.max_batch_size,
        array_per_script=args.array_per_script,
        max_cpus=args.max_cpus,
        ping_interval=args.ping_interval,
        job_scripts=args.scripts
    )
    
    manager.run()
    
if __name__ == "__main__":
    main()
