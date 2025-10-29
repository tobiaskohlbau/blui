<script lang="ts">
	import { onMount } from 'svelte';
	import type { PageProps } from './$types';
	import { invalidateAll } from '$app/navigation';

	let { data }: PageProps = $props();

	onMount(() => {
		function forever() {
			invalidateAll();
			setTimeout(forever, 5000);
		}
		forever();
	});

	async function chamber_led(on: bool) {
		await fetch(`/api/printer/led/chamber?state=${on ? 'on' : 'off'}`);
	}

	async function pause() {
		await fetch('/api/printer/pause');
	}

	async function resume() {
		await fetch('/api/printer/resume');
	}

	async function stop() {
		await fetch('/api/printer/stop');
	}

	const decimals = 1;
</script>

<div class="grid">
	<section>
		<div class="card webcam">
			<h2>Webcam</h2>
			<div style="margin-top:8px">
				<img id="webcam-img" alt="webcam" src={data.image} />
			</div>
		</div>

		<div style="height:14px"></div>

		<div class="card">
			<h2>Temperatures</h2>
			<div class="temps">
				<div class="temp-row">
					<div class="temp-box">
						<div class="temp-icon">🔥</div>
						<div>
							<div class="temp-val">{Number(data.temperature.nozzle).toFixed(decimals)} °C</div>
							<div class="temp-meta">
								Nozzle / Target: <span
									>{Number(data.temperature.nozzle_target).toFixed(decimals)}</span
								>
							</div>
						</div>
					</div>
					<div class="temp-box">
						<div class="temp-icon">🛏️</div>
						<div>
							<div class="temp-val">{Number(data.temperature.bed).toFixed(decimals)} °C</div>
							<div class="temp-meta">
								Bed / Target: <span>{Number(data.temperature.bed_target).toFixed(decimals)}</span>
							</div>
						</div>
					</div>
				</div>

				<div class="temp-row">
					<div class="temp-box">
						<div class="temp-icon">⚙️</div>
						<div>
							<div class="temp-val">{data.fan.cooling_speed} %</div>
							<div class="temp-meta">Fan speed</div>
						</div>
					</div>
					<div class="temp-box">
						<div class="temp-icon">⏳</div>
						<div>
							<div class="temp-val">{data.print_percent} %</div>
							<div class="temp-meta">Print progress</div>
						</div>
					</div>
				</div>
			</div>
		</div>
	</section>

	<aside>
		<div class="card">
			<h2>Job Controls</h2>
			<div class="controls">
				<button class="btn" onclick={() => pause()}>Pause</button>
				<button class="btn" onclick={() => resume()}>Resume</button>
				<button class="btn" onclick={() => stop()}>Stop</button>
				<button class="btn" onclick={() => chamber_led(true)}>LED On</button>
				<button class="btn" onclick={() => chamber_led(false)}>LED Off</button>
			</div>
		</div>
	</aside>
</div>

<style>
	.grid {
		display: grid;
		grid-template-columns: 420px 1fr;
		gap: 18px;
	}

	.card {
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.02), rgba(255, 255, 255, 0.01));
		padding: 14px;
		border-radius: 12px;
	}
	.card h2 {
		margin: 0 0 8px 0;
		font-size: 14px;
	}

	.webcam {
		border-radius: 10px;
		overflow: hidden;
	}
	.webcam img {
		display: block;
		width: 100%;
		height: 260px;
		object-fit: cover;
	}

	.temps {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.temp-row {
		display: flex;
		gap: 10px;
	}

	.temp-box {
		flex: 1;
		padding: 12px;
		border-radius: 10px;
		background: linear-gradient(90deg, rgba(255, 255, 255, 0.018), rgba(255, 255, 255, 0.01));
		display: flex;
		align-items: center;
		gap: 12px;
	}
	.temp-icon {
		width: 48px;
		height: 48px;
		border-radius: 10px;
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.02), rgba(255, 255, 255, 0.01));
		display: flex;
		align-items: center;
		justify-content: center;
	}
	.temp-val {
		font-weight: 700;
		font-size: 18px;
	}
	.temp-meta {
		font-size: 12px;
		color: var(--muted);
	}

	.controls {
		display: flex;
		gap: 10px;
	}
</style>
