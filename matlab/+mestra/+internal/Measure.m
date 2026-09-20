classdef Measure
%Measure  The measure of a cell, from its type and its nodes.
%
%   Specification section 3 says a weight array is "computed from
%   connectivity, never imported", and section 20 fixes the cell type
%   codes and the node order within a cell, which is VTK's.  This
%   class is the arithmetic that follows from those two sentences:
%   the length of a line, the area of a triangle, a quadrilateral or
%   a polygon, and the volume of a tetrahedron, a hexahedron, a wedge
%   or a pyramid.
%
%   A code this class cannot measure is refused by name rather than
%   approximated.  The quadratic cells, codes 21 to 27, have curved
%   edges, and measuring them by their corner nodes would be a number
%   that looks right and is not; a caller who wants that number can
%   compute it and store it as a `derived` array, where the recipe is
%   written down.
%
%   See also mestra.computeWeights, mestra.integrate.

    properties (Constant)
        % code -> [node count, topological dimension] (section 20).
        table = containers.Map( ...
            { 1,      3,      5,      7,      9,     10,     12, ...
             13,     14,     21,     22,     23,     24,     25, ...
             26,     27}, ...
            {[1 0], [2 1], [3 2], [0 2], [4 2], [4 3], [8 3], ...
             [6 3], [5 3], [3 1], [6 2], [8 2], [10 3], [20 3], ...
             [15 3], [13 3]})
    end

    methods (Static)

        function d = dimensionOf(code)
        %dimensionOf  The topological dimension of a cell type.
            key = double(code);
            if ~mestra.internal.Measure.table.isKey(key)
                error('mestra:E21', ...
                      ['E21: cell type %d is not one of the codes of ' ...
                       'section 20'], key);
            end
            entry = mestra.internal.Measure.table(key);
            d = entry(2);
        end

        function m = cell(code, points)
        %cell  The measure of one cell.
        %
        %   POINTS is d-by-n: one column per node of the cell, in the
        %   VTK order section 20 fixes, with d the spatial dimension.
            key = double(code);
            M = mestra.internal.Measure;
            switch key
                case 1                      % vertex
                    m = 0;
                case 3                      % line
                    m = norm(points(:, 2) - points(:, 1));
                case 5                      % triangle
                    m = M.triangle(points(:, 1), points(:, 2), points(:, 3));
                case 7                      % polygon
                    m = M.polygon(points);
                case 9                      % quadrilateral
                    m = M.polygon(points(:, [1 2 3 4]));
                case 10                     % tetrahedron
                    m = M.tetra(points(:, 1), points(:, 2), points(:, 3), ...
                                points(:, 4));
                case 12                     % hexahedron
                    m = M.hexahedron(points);
                case 13                     % wedge
                    m = M.wedge(points);
                case 14                     % pyramid
                    m = M.pyramid(points);
                case {21, 22, 23, 24, 25, 26, 27}
                    error('mestra:weights', ...
                          ['cell type %d is a quadratic cell, whose ' ...
                           'edges are curved; this package does not ' ...
                           'measure one, because measuring it by its ' ...
                           'corner nodes would be a number that looks ' ...
                           'right and is not. Store the measure you ' ...
                           'want as a derived array, whose recipe says ' ...
                           'how it was found'], key);
                otherwise
                    error('mestra:E21', ...
                          ['E21: cell type %d is not one of the codes ' ...
                           'of section 20'], key);
            end
        end

        function a = triangle(p1, p2, p3)
        %triangle  Half the length of the cross product of two edges,
        %   in two or three dimensions.
            u = p2 - p1;
            v = p3 - p1;
            a = 0.5 * norm(mestra.internal.Measure.cross3(u, v));
        end

        function a = polygon(points)
        %polygon  Newell's area: the length of half the sum of the
        %   cross products around the boundary.  It is the shoelace
        %   formula in two dimensions and the area of the best-fitting
        %   plane's projection in three, and it is exact for a planar
        %   polygon of any node count.
            n = size(points, 2);
            if n < 3
                a = 0;
                return
            end
            total = zeros(3, 1);
            for i = 1:n
                j = mod(i, n) + 1;
                total = total + mestra.internal.Measure.cross3( ...
                    points(:, i), points(:, j));
            end
            a = 0.5 * norm(total);
        end

        function v = tetra(p1, p2, p3, p4)
        %tetra  One sixth of the determinant of the three edges.
            M = mestra.internal.Measure;
            a = M.to3(p2) - M.to3(p1);
            b = M.to3(p3) - M.to3(p1);
            c = M.to3(p4) - M.to3(p1);
            v = abs(dot(a, cross(b, c))) / 6;
        end

        function v = hexahedron(points)
        %hexahedron  Six tetrahedra on the VTK node order of section
        %   20, which is exact for a hexahedron with planar faces and
        %   is the standard decomposition for one without.
            faces = [1 2 3 6; 1 3 4 8; 1 6 3 8; 1 5 6 8; 3 6 7 8];
            v = mestra.internal.Measure.sumTetras(points, faces);
        end

        function v = wedge(points)
        %wedge  Three tetrahedra on the VTK wedge order.
            faces = [1 2 3 5; 1 3 5 6; 1 4 5 6];
            v = mestra.internal.Measure.sumTetras(points, faces);
        end

        function v = pyramid(points)
        %pyramid  Two tetrahedra on the VTK pyramid order: a
        %   quadrilateral base and an apex.
            faces = [1 2 3 5; 1 3 4 5];
            v = mestra.internal.Measure.sumTetras(points, faces);
        end

        function v = sumTetras(points, faces)
            v = 0;
            for i = 1:size(faces, 1)
                f = faces(i, :);
                v = v + mestra.internal.Measure.tetra(points(:, f(1)), ...
                    points(:, f(2)), points(:, f(3)), points(:, f(4)));
            end
        end

        function c = cross3(u, v)
        %cross3  A cross product that works on 1, 2 or 3 components.
            M = mestra.internal.Measure;
            c = cross(M.to3(u), M.to3(v));
        end

        function p = to3(p)
        %to3  A point padded to three components with zeros.
            p = reshape(double(p), [], 1);
            if numel(p) < 3
                p(end + 1:3) = 0;
            end
            p = p(1:3);
        end
    end
end
