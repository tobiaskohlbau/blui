import type { PageLoad } from './$types';
import { dev } from '$app/environment';

export const load: PageLoad = async ({ params, fetch }) => {
	if (!dev) {
		const status = await fetch(`/api/printer/status`).then((r) => r.json());
		const image = await fetch(`/api/webcam.jpg`)
			.then((r) => r.blob())
			.then(
				(blob) =>
					new Promise((callback) => {
						let reader = new FileReader();
						reader.onload = function () {
							callback(this.result);
						};
						reader.readAsDataURL(blob);
					})
			);
		return {
			...status,
			image: image
		};
	} else {
		return {
			temperature: {
				nozzle: 220.3,
				nozzle_target: 220.0,
				bed: 49.8,
				bed_target: 55.0
			},
			fan: {
				cooling_speed: 73
			},
			print_percent: 80,
			image: null
		};
	}
};
