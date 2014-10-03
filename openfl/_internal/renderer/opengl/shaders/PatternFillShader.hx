package openfl._internal.renderer.opengl.shaders;

import lime.graphics.GLRenderContext;
import lime.graphics.opengl.GLUniformLocation;

class PatternFillShader extends AbstractShader {

	public var offsetVector:GLUniformLocation;
	public var translationMatrix:GLUniformLocation;
	public var patternMatrix:GLUniformLocation;
	public var patternTL:GLUniformLocation;
	public var patternBR:GLUniformLocation;
	public var pattern:GLUniformLocation;
	public var alpha:GLUniformLocation;
	
	public function new(gl:GLRenderContext) {
		super(gl);
		
		vertexSrc = [
			'attribute vec2 aVertexPosition;',
			'uniform mat3 translationMatrix;',
			'uniform vec2 projectionVector;',
			'uniform vec2 offsetVector;',
			'uniform mat3 patternMatrix;',
			
			'varying vec2 vPos;',
			
			'void main(void) {',
			'   vec3 v = translationMatrix * vec3(aVertexPosition , 1.0);',
			'   v -= offsetVector.xyx;',
			'   gl_Position = vec4( v.x / projectionVector.x -1.0, v.y / -projectionVector.y + 1.0 , 0.0, 1.0);',
			'   vPos = (patternMatrix * vec3(aVertexPosition, 1)).xy;',
			//'   vPos = aVertexPosition;',
			'}'

		];
		
		fragmentSrc = [
			'precision mediump float;',
			'uniform float alpha;',
			'uniform vec2 patternTL;',
			'uniform vec2 patternBR;',
			'uniform sampler2D sampler;',
			
			'varying vec2 vPos;',
			
			'void main(void) {',
			'   vec2 pos = mix(patternTL, patternBR, vPos);',
			'   gl_FragColor = vec4(texture2D(sampler, pos).rgb * alpha, alpha);',
			'}'
		];
		
		init ();
		
	}
	
	public override function init ():Void {
		
		super.init ();
		
		translationMatrix = gl.getUniformLocation (program, 'translationMatrix');
		projectionVector = gl.getUniformLocation (program, 'projectionVector');
		offsetVector = gl.getUniformLocation (program, 'offsetVector');
		
		patternMatrix = gl.getUniformLocation (program, 'patternMatrix');
		patternTL = gl.getUniformLocation (program, 'patternTL');
		patternBR = gl.getUniformLocation (program, 'patternBR');
		pattern = gl.getUniformLocation (program, 'sampler');
		alpha = gl.getUniformLocation (program, 'alpha');
		
		aVertexPosition = gl.getAttribLocation (program, 'aVertexPosition');
		
		attributes = [aVertexPosition];
		
	}
	
}