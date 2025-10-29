<script lang="ts">
	import favicon from '$lib/assets/favicon.svg';
	import { onMount } from 'svelte';

	let { children } = $props();
	let theme = $state(undefined);

	onMount(() => {
		theme = localStorage.getItem('theme') || 'os';
	});

	$effect(() => {
		if (theme !== 'os') {
			localStorage.setItem('theme', theme);
		} else {
			localStorage.removeItem('theme');
		}
		if (theme === 'light') {
			document.documentElement.classList.add('light');
			document.documentElement.classList.remove('dark');
		} else if (theme === 'dark') {
			document.documentElement.classList.add('dark');
			document.documentElement.classList.remove('light');
		} else {
			document.documentElement.classList.remove('light', 'dark');
		}
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<div class="app">
	<aside class="sidebar">
		<div class="brand">
			<div class="logo">blUI</div>
			<div>
				<h1>blUI</h1>
				<div class="small">Cloudless by Design</div>
			</div>
		</div>

		<nav class="nav">
			<a href="/" class="active">Dashboard</a>
		</nav>

		<footer class="footer">
			<input type="radio" id="theme-os" bind:group={theme} value="os" class="theme-radio" checked />
			<label for="theme-os" class="btn">Auto</label>
			<input type="radio" id="theme-light" bind:group={theme} value="light" class="theme-radio" />
			<label for="theme-light" class="btn">Light</label>
			<input type="radio" id="theme-dark" bind:group={theme} value="dark" class="theme-radio" />
			<label for="theme-dark" class="btn">Dark</label>
		</footer>
	</aside>

	<main class="main">
		{@render children?.()}
	</main>
</div>

<style>
	:global {
		* {
			box-sizing: border-box;
		}

		html,
		body {
			height: 100%;
			margin: 0;
			background: linear-gradient(180deg, var(--bg) 0%, var(--bg) 100%);
			color: var(--muted);
		}

		a {
			color: var(--accent-2);
			text-decoration: none;
		}

		:root {
			/* Light theme */
			--bg-light: #ffffff;
			--card-light: #f8fafc;
			--muted-light: #64748b;
			--accent-light: #10b981;
			--accent-2-light: #3b82f6;
			--glass-light: rgba(0, 0, 0, 0.04);
			--shadow-light: 0 6px 18px rgba(0, 0, 0, 0.1);

			/* Dark theme */
			--bg-dark: #0f1724;
			--card-dark: #0b1220;
			--muted-dark: #98a0b3;
			--accent-dark: #58b892;
			--accent-2-dark: #60a5fa;
			--glass-dark: rgba(255, 255, 255, 0.04);
			--shadow-dark: 0 6px 18px rgba(2, 6, 23, 0.6);

			/* Default to dark */
			--bg: var(--bg-dark);
			--card: var(--card-dark);
			--muted: var(--muted-dark);
			--accent: var(--accent-dark);
			--accent-2: var(--accent-2-dark);
			--glass: var(--glass-dark);
			--shadow: var(--shadow-dark);

			--radius: 14px;
			font-family:
				Inter,
				ui-sans-serif,
				system-ui,
				-apple-system,
				'Segoe UI',
				Roboto,
				'Helvetica Neue',
				Arial;
		}

		@media (prefers-color-scheme: light) {
			:root {
				--bg: var(--bg-light);
				--card: var(--card-light);
				--muted: var(--muted-light);
				--accent: var(--accent-light);
				--accent-2: var(--accent-2-light);
				--glass: var(--glass-light);
				--shadow: var(--shadow-light);
			}
		}

		:root.light {
			--bg: var(--bg-light);
			--card: var(--card-light);
			--muted: var(--muted-light);
			--accent: var(--accent-light);
			--accent-2: var(--accent-2-light);
			--glass: var(--glass-light);
			--shadow: var(--shadow-light);
		}

		:root.dark {
			--bg: var(--bg-dark);
			--card: var(--card-dark);
			--muted: var(--muted-dark);
			--accent: var(--accent-dark);
			--accent-2: var(--accent-2-dark);
			--glass: var(--glass-dark);
			--shadow: var(--shadow-dark);
		}

		.btn {
			flex: 1;
			padding: 8px;
			border-radius: 8px;
			background: var(--glass);
			color: var(--muted);
			text-align: center;
			cursor: pointer;
			transition:
				background 0.2s,
				color 0.2s;
			font-size: 12px;
			border: 0;

			&:hover {
				background: var(--glass);
				color: var(--accent-2);
			}
		}
	}

	.app {
		display: grid;
		grid-template-columns: 260px 1fr;
		gap: 20px;
		min-height: 100vh;
		padding: 28px;
	}

	.sidebar {
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.02), rgba(255, 255, 255, 0.015));
		padding: 18px;
		border-radius: 16px;
		box-shadow: var(--shadow);
		display: flex;
		flex-direction: column;
		min-height: calc(100vh - 56px);
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 12px;
		margin-bottom: 10px;

		h1 {
			font-size: 16px;
			margin: 0;
		}
	}

	.logo {
		width: 44px;
		height: 44px;
		border-radius: 10px;
		background: linear-gradient(135deg, var(--accent), var(--accent-2));
		display: flex;
		align-items: center;
		justify-content: center;
		font-weight: 700;
	}

	.nav {
		margin-top: 12px;
		a {
			display: flex;
			align-items: center;
			padding: 10px;
			border-radius: 10px;
			color: var(--muted);
			gap: 10px;
			margin-bottom: 6px;

			&.active,
			&:hover {
				background: var(--glass);
				color: var(--accent-2);
			}
		}
	}

	.footer {
		margin-top: auto;
		padding-top: 20px;
		display: flex;
		gap: 8px;
	}

	.theme-radio {
		display: none;
	}

	.theme-radio:checked + .btn {
		background: var(--accent);
		color: white;
	}

	.main {
		padding: 18px;
		border-radius: 16px;
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.01), rgba(255, 255, 255, 0.005));
		box-shadow: var(--shadow);
	}
</style>
